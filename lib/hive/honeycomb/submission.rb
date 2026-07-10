require "fileutils"
require "json"
require "tmpdir"
require "hive/gh"
require "hive/honeycomb"
require "hive/lock"
require "hive/paths"

module Hive
  module Honeycomb
    class Submission
      WRITE_PERMISSIONS = %w[WRITE MAINTAIN ADMIN].freeze
      Result = Data.define(:pr_url, :repository, :push_repository, :branch, :mode, :head, :base)

      class Error < Hive::GhError; end

      class PartialError < Error
        attr_reader :repository, :branch

        def initialize(message, repository:, branch:)
          @repository = repository
          @branch = branch
          super(message)
        end
      end

      def self.submit(**kwargs)
        new(**kwargs).submit
      end

      def initialize(package:, repository:, cfg: {}, cache_path: nil,
                     runner: Hive::Gh.method(:capture3), locker: nil)
        @package = package
        @repository = repository
        @cfg = cfg || {}
        @cache_path = cache_path || Hive::Paths.honeycomb_cache_path(repository)
        @runner = runner
        @locker = locker || ->(path, &block) { Hive::Lock.with_commit_lock(path, &block) }
      end

      def submit
        @locker.call(File.dirname(@cache_path)) do
          authenticate!
          repository_info = fetch_repository_info
          prepare_cache(repository_info.fetch("default_branch"))
          route = submission_route(repository_info)
          branch = "submit-#{@package.id}-v#{@package.version}"
          refuse_branch_collisions!(branch, route.fetch("remote"))
          submit_from_worktree(repository_info, route, branch)
        end
      end

      private

      def authenticate!
        _out, err, status = capture("gh", "auth", "status")
        return if status.success?

        raise Error, "gh not authenticated (`gh auth login`): #{err.to_s.strip}"
      end

      def fetch_repository_info
        fields = "nameWithOwner,defaultBranchRef,viewerPermission"
        out = run!("gh", "repo", "view", @repository, "--json", fields, label: "gh repo view")
        data = JSON.parse(out)
        name = data["nameWithOwner"].to_s
        branch = data.dig("defaultBranchRef", "name").to_s
        permission = data["viewerPermission"].to_s
        unless name == @repository && !branch.empty? && !permission.empty?
          raise Error,
                "configured honeycomb repository #{@repository.inspect} returned invalid repository metadata"
        end

        { "name" => name, "default_branch" => branch, "permission" => permission }
      rescue JSON::ParserError => e
        raise Error, "gh repo view returned invalid JSON for #{@repository}: #{e.message}"
      end

      def prepare_cache(default_branch)
        if File.directory?(File.join(@cache_path, ".git"))
          origin = run!("git", "-C", @cache_path, "remote", "get-url", "origin", label: "git remote").strip
          unless origin_matches_repository?(origin)
            raise Error,
                  "cached honeycomb origin #{origin.inspect} does not match configured repository #{@repository.inspect}"
          end
        elsif File.exist?(@cache_path)
          raise Error, "honeycomb cache #{@cache_path} exists but is not a git checkout"
        else
          FileUtils.mkdir_p(File.dirname(@cache_path))
          run!(
            "gh", "repo", "clone", @repository, @cache_path, "--", "--filter=blob:none",
            label: "gh repo clone"
          )
        end

        run!(
          "git", "-C", @cache_path, "fetch", "--prune", "origin", default_branch,
          label: "git fetch"
        )
      end

      def origin_matches_repository?(origin)
        normalized = origin.to_s.strip.sub(/\.git\z/, "")
        normalized == "https://github.com/#{@repository}" ||
          normalized == "ssh://git@github.com/#{@repository}" ||
          normalized == "git@github.com:#{@repository}"
      end

      def submission_route(repository_info)
        if WRITE_PERMISSIONS.include?(repository_info.fetch("permission"))
          return {
            "mode" => "direct",
            "push_repository" => @repository,
            "remote" => "https://github.com/#{@repository}.git",
            "push_remote" => "origin",
            "head_prefix" => nil
          }
        end

        login = run!("gh", "api", "user", "--jq", ".login", label: "gh api user").strip
        raise Error, "gh api user returned a blank login" if login.empty?

        repository_name = @repository.split("/", 2).last
        fork = "#{login}/#{repository_name}"
        _out, _err, status = capture("gh", "repo", "view", fork, "--json", "nameWithOwner")
        unless status.success?
          run!("gh", "repo", "fork", @repository, "--clone=false", label: "gh repo fork")
        end
        {
          "mode" => "fork",
          "push_repository" => fork,
          "remote" => "https://github.com/#{fork}.git",
          "push_remote" => "https://github.com/#{fork}.git",
          "head_prefix" => login
        }
      end

      def refuse_branch_collisions!(branch, remote)
        _out, err, local = capture(
          "git", "-C", @cache_path, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"
        )
        raise Error, "local branch #{branch.inspect} already exists in honeycomb cache" if local.success?
        unless local.exitstatus == 1
          raise Error, "could not inspect local honeycomb branches: #{err.to_s.strip}"
        end

        _out, err, remote_status = capture(
          "git", "ls-remote", "--exit-code", "--heads", remote, "refs/heads/#{branch}"
        )
        raise Error, "remote branch #{branch.inspect} already exists at #{remote}" if remote_status.success?
        return if remote_status.exitstatus == 2

        raise Error, "could not inspect remote honeycomb branches: #{err.to_s.strip}"
      end

      def submit_from_worktree(repository_info, route, branch)
        worktree_parent = File.join(File.dirname(@cache_path), "worktrees")
        FileUtils.mkdir_p(worktree_parent)
        worktree = Dir.mktmpdir("submit-", worktree_parent)
        Dir.rmdir(worktree)
        added = false
        pushed = false
        begin
          run!(
            "git", "-C", @cache_path, "worktree", "add", "-b", branch, worktree,
            "origin/#{repository_info.fetch('default_branch')}",
            label: "git worktree add"
          )
          added = true
          replace_package(worktree)
          commit_package(worktree)
          run!(
            "git", "-C", worktree, "push", "-u", route.fetch("push_remote"), branch,
            label: "git push"
          )
          pushed = true
          head = route["head_prefix"] ? "#{route.fetch('head_prefix')}:#{branch}" : branch
          pr_url = create_pr(repository_info, route, branch, head)
          Result.new(
            pr_url: pr_url,
            repository: @repository,
            push_repository: route.fetch("push_repository"),
            branch: branch,
            mode: route.fetch("mode"),
            head: head,
            base: repository_info.fetch("default_branch")
          )
        rescue Error => e
          if pushed
            raise PartialError.new(
              "#{e.message}; pushed branch #{route.fetch('push_repository')}:#{branch} remains available for recovery",
              repository: route.fetch("push_repository"),
              branch: branch
            )
          end
          raise
        ensure
          cleanup_worktree(worktree, branch, added)
        end
      end

      def replace_package(worktree)
        target = File.join(worktree, "workflows", @package.id)
        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(@package.package_root, target)
      rescue SystemCallError => e
        raise Error, "failed to materialize honeycomb package: #{e.message}"
      end

      def commit_package(worktree)
        relative = "workflows/#{@package.id}"
        run!("git", "-C", worktree, "add", "--", relative, label: "git add")
        run!(
          "git", "-c", "user.name=Hive", "-c", "user.email=hive@localhost",
          "-c", "commit.gpgsign=false", "-C", worktree, "commit", "-m",
          "workflow(#{@package.id}): publish v#{@package.version}",
          label: "git commit"
        )
      end

      def create_pr(repository_info, route, branch, head)
        title = "workflow(#{@package.id}): publish v#{@package.version}"
        out, err, status = capture(
          "gh", "pr", "create",
          "-R", @repository,
          "--title", title,
          "--body", pr_body(route, branch),
          "--base", repository_info.fetch("default_branch"),
          "--head", head
        )
        unless status.success?
          raise Error, "gh pr create failed: #{err.to_s.strip}"
        end

        url = out.lines.first.to_s.strip
        raise Error, "gh pr create returned no PR URL" if url.empty?

        url
      end

      def pr_body(route, branch)
        manifest = @package.manifest
        aggregate = @package.permission_summary.fetch("aggregate")
        review = Array(manifest["review_required"])
        [
          "Publishes honeycomb `#{@package.id}` version `#{@package.version}`.",
          "",
          "- Aggregate SHA-256: `#{manifest.fetch('aggregate_sha256')}`",
          "- Secret rules: v#{manifest.fetch('rule_sets').fetch('secrets')}",
          "- Deny rules: v#{manifest.fetch('rule_sets').fetch('deny')}",
          "- Permission presets: #{Array(aggregate['presets']).join(', ')}",
          "- Shell exposure: #{Array(aggregate['shell_exposures']).join(', ')}",
          "- Review-required findings: #{review.length}",
          "- Push route: #{route.fetch('push_repository')}:#{branch}"
        ].join("\n")
      end

      def cleanup_worktree(worktree, branch, added)
        if added
          capture("git", "-C", @cache_path, "worktree", "remove", "--force", worktree)
          capture("git", "-C", @cache_path, "branch", "-D", branch)
        end
        FileUtils.rm_rf(worktree)
      rescue StandardError
        FileUtils.rm_rf(worktree)
      end

      def capture(*argv)
        @runner.call(*argv, cfg: @cfg)
      rescue Hive::GhError => e
        raise Error, e.message
      end

      def run!(*argv, label:)
        out, err, status = capture(*argv)
        return out if status.success?

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise Error, "#{label} failed: #{detail[0, 500]}"
      end
    end
  end
end
