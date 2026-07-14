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
      # GitHub fork creation is asynchronous: a freshly created fork is not
      # immediately pushable, so poll for readiness before the first push.
      FORK_READY_ATTEMPTS = 12
      FORK_READY_INTERVAL_SEC = 2.5
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
                     runner: Hive::Gh.method(:capture3), locker: nil, sleeper: nil)
        @package = package
        @repository = repository
        @cfg = cfg || {}
        @cache_path = cache_path || Hive::Paths.honeycomb_cache_path(repository)
        @runner = runner
        @locker = locker || ->(path, &block) { Hive::Lock.with_commit_lock(path, &block) }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
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
        out, err, status = capture("gh", "auth", "status")
        return if status.success?

        raise Error, "gh not authenticated (`gh auth login`): #{command_detail(out, err)}"
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
        out, err, status = capture("gh", "repo", "view", fork, "--json", "nameWithOwner,isFork,parent")
        if status.success?
          # A repository with the fork's name already exists — confirm it is
          # actually a fork of the configured upstream before pushing a
          # submission branch into it (an unrelated namesake would swallow the
          # push and only fail later at cross-repo PR creation).
          verify_fork_of_upstream!(fork, out)
        else
          # Only a genuine "fork does not exist yet" (404) should trigger a fork
          # attempt. A transient auth/network failure must fail closed rather than
          # spuriously forking on top of an already-existing fork.
          unless fork_missing?(err)
            raise Error, "could not determine fork status for #{fork}: #{command_detail(out, err)}"
          end

          create_fork!(fork)
        end
        {
          "mode" => "fork",
          "push_repository" => fork,
          "remote" => "https://github.com/#{fork}.git",
          "push_remote" => "https://github.com/#{fork}.git",
          "head_prefix" => login
        }
      end

      def verify_fork_of_upstream!(fork, json)
        data = JSON.parse(json)
        parent = data.dig("parent", "nameWithOwner").to_s
        return if data["isFork"] == true && parent == @repository

        raise Error,
              "existing repository #{fork} is not a fork of #{@repository} " \
              "(parent: #{parent.empty? ? 'none' : parent}); refusing to push a submission there"
      rescue JSON::ParserError => e
        raise Error, "gh repo view returned invalid JSON for #{fork}: #{e.message}"
      end

      # Creates the fork without reconfiguring any local git remotes
      # (`--remote=false`) and from a neutral directory outside a checkout, so
      # the isolated-cache/worktree guarantee holds even when publish runs from
      # inside an unrelated repository. Then waits for GitHub to finish the
      # asynchronous fork creation before the caller pushes to it.
      def create_fork!(fork)
        run!(
          "gh", "repo", "fork", @repository, "--clone=false", "--remote=false",
          label: "gh repo fork", chdir: File.dirname(@cache_path)
        )
        await_fork_ready!(fork)
      end

      def await_fork_ready!(fork)
        FORK_READY_ATTEMPTS.times do |attempt|
          _out, _err, status = capture("gh", "repo", "view", fork, "--json", "nameWithOwner")
          return if status.success?

          @sleeper.call(FORK_READY_INTERVAL_SEC) if attempt < FORK_READY_ATTEMPTS - 1
        end
        raise Error, "fork #{fork} was not ready after creation; re-run the publish to retry"
      end

      def fork_missing?(stderr)
        text = stderr.to_s
        text.include?("Could not resolve to a Repository") ||
          text.match?(/\bHTTP 404\b/) ||
          text.match?(/\bnot found\b/i)
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
        rescue StandardError => e
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
        workflows_dir = File.join(worktree, "workflows")
        # The registry tree could track `workflows` as a symlink; following it
        # would make the rm_rf/cp_r below delete or write `<target>/<id>`
        # outside the disposable worktree. Refuse anything but a real directory
        # resolving inside the worktree.
        ensure_workflows_within_worktree!(worktree, workflows_dir)
        target = File.join(workflows_dir, @package.id)
        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(@package.package_root, target)
      rescue SystemCallError => e
        raise Error, "failed to materialize honeycomb package: #{e.message}"
      end

      def ensure_workflows_within_worktree!(worktree, workflows_dir)
        if File.symlink?(workflows_dir)
          raise Error, "registry worktree 'workflows' is a symlink; refusing to write through it"
        end
        return unless File.exist?(workflows_dir)

        real_worktree = File.realpath(worktree)
        real_workflows = File.realpath(workflows_dir)
        return if File.directory?(real_workflows) && real_workflows == File.join(real_worktree, "workflows")

        raise Error, "registry worktree 'workflows' path escapes the disposable worktree"
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
        lines = [
          "Publishes honeycomb `#{@package.id}` version `#{@package.version}`.",
          "",
          "- Aggregate SHA-256: `#{manifest.fetch('aggregate_sha256')}`",
          "- Secret rules: v#{manifest.fetch('rule_sets').fetch('secrets')}",
          "- Deny rules: v#{manifest.fetch('rule_sets').fetch('deny')}",
          "- Permission presets: #{Array(aggregate['presets']).join(', ')}",
          "- Shell exposure: #{Array(aggregate['shell_exposures']).join(', ')}",
          "- Review-required findings: #{review.length}",
          "- Push route: #{route.fetch('push_repository')}:#{branch}"
        ]
        # Registry reviewers need each justified high-risk finding spelled out —
        # rule, location, owning contexts, and justification — not just a count.
        unless review.empty?
          lines << "" << "## Review-required findings"
          review.each do |record|
            location = [ record["file"], record["line"] ].compact.join(":")
            lines << "- `#{record['rule']}` at #{location}"
            lines << "  - contexts: #{Array(record['contexts']).join(', ')}"
            lines << "  - justification: #{record['justification']}"
          end
        end
        lines.join("\n")
      end

      def cleanup_worktree(worktree, branch, added)
        if added
          log_cleanup_failure("git worktree remove", worktree,
                              *capture("git", "-C", @cache_path, "worktree", "remove", "--force", worktree))
        end
        # Delete the branch UNCONDITIONALLY, independent of `added`: `git worktree
        # add -b` can create the branch ref before it fails to register the
        # worktree (ENOSPC / permission / interrupt), leaving `added == false`
        # while the branch leaked. A leaked cache branch blocks the next
        # same-version publish with a confusing collision error, so surface
        # (rather than swallow) a failed deletion even though cleanup is
        # best-effort. When the ref never existed this is a logged no-op.
        log_cleanup_failure("git branch -D #{branch}", worktree,
                            *capture("git", "-C", @cache_path, "branch", "-D", branch))
        FileUtils.rm_rf(worktree)
      rescue StandardError => e
        warn "hive: honeycomb worktree cleanup failed for #{worktree}: #{e.class}: #{e.message}"
        FileUtils.rm_rf(worktree)
      end

      def log_cleanup_failure(action, worktree, _out, err, status)
        return if status.success?

        warn "hive: honeycomb cleanup step `#{action}` failed for #{worktree}: #{err.to_s.strip}"
      end

      def capture(*argv, chdir: nil)
        @runner.call(*argv, chdir: chdir, cfg: @cfg)
      rescue Hive::GhError => e
        raise Error, e.message
      end

      def run!(*argv, label:, chdir: nil)
        out, err, status = capture(*argv, chdir: chdir)
        return out if status.success?

        raise Error, "#{label} failed: #{command_detail(out, err)[0, 500]}"
      end

      # Prefer stderr for a command's failure detail, falling back to stdout when
      # stderr is blank. Single definition so authenticate!/run! can't drift.
      def command_detail(out, err)
        err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
      end
    end
  end
end
