require "digest"
require "fileutils"
require "json"
require "tempfile"
require "uri"
require "hive/gh"
require "hive/paths"
require "hive/workflow_package/manifest"
require "hive/workflow_package/publish_receipt"
require "hive/workflow_package/registry_manifest"
require "hive/workflow_package/safe_file"

module Hive
  module WorkflowPackage
    class PublishAuthenticationError < Hive::ConfigError; end

    class PublishOfflineError < Hive::Error
      def exit_code = Hive::ExitCodes::UNAVAILABLE
    end

    class PublishAmbiguousError < Hive::Error
      def exit_code = Hive::ExitCodes::TEMPFAIL
    end

    # Bounded git/GitHub transport. Publication policy and replay decisions
    # deliberately live in RegistrySubmission, where they can be tested with a
    # hermetic fake rather than inferred from command exit codes.
    class RegistryGateway
      REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
      SHA = /\A[0-9a-f]{40}\z/
      PR_URL = %r{\Ahttps://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*\z}
      PullRequest = Data.define(
        :number, :url, :state, :draft, :merged_at, :head_repository,
        :head_branch, :head_oid, :base_branch, :body
      )

      def initialize(runner: nil, sleeper: nil, objects_root: Hive::Paths.workflow_publish_objects_root)
        @runner = runner || ->(args, chdir: nil) { Hive::Gh.capture3(*args, chdir: chdir) }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @objects_root = objects_root
      end

      def authenticate!
        run!([ "gh", "auth", "status" ], "GitHub authentication", error: PublishAuthenticationError)
        data = json!([ "gh", "api", "user" ], "GitHub identity", error: PublishAuthenticationError)
        login = data.is_a?(Hash) ? data["login"].to_s : ""
        raise PublishAuthenticationError, "GitHub identity is unavailable" unless login.match?(/\A[A-Za-z0-9-]{1,39}\z/)

        login
      end

      def base_oid(repository, branch)
        validate_repository!(repository)
        data = json!([ "gh", "api", "repos/#{repository}/git/ref/heads/#{escape(branch)}" ], "registry base lookup")
        oid = data.dig("object", "sha").to_s.downcase
        raise PublishOfflineError, "registry base lookup returned invalid data" unless SHA.match?(oid)

        oid
      end

      def direct_permission?(repository, login)
        out, err, status = run([ "gh", "api", "repos/#{repository}/collaborators/#{escape(login)}/permission" ])
        return false if !status.success? && err.to_s.match?(/\b404\b|Not Found/i)
        raise PublishOfflineError, "registry permission lookup failed" unless status.success?
        data = JSON.parse(out)
        %w[admin maintain write].include?(data["permission"])
      rescue JSON::ParserError
        raise PublishOfflineError, "registry permission lookup returned invalid data"
      end

      def ensure_fork(repository, login)
        validate_repository!(repository)
        fork = "#{login}/#{repository.split('/').last}"
        10.times do |attempt|
          data = json_optional([ "gh", "repo", "view", fork, "--json", "nameWithOwner,parent" ])
          if data
            validate_fork_data!(data, fork, repository, login)
            return fork
          end
          run!([ "gh", "repo", "fork", repository, "--clone=false", "--remote=false" ], "registry fork creation") if attempt.zero?
          @sleeper.call(1) unless attempt == 9
        end
        raise PublishAmbiguousError, "registry fork outcome is unknown"
      end

      def verify_fork!(repository, parent:, owner:)
        validate_repository!(repository)
        validate_repository!(parent)
        data = json!(
          [ "gh", "repo", "view", repository, "--json", "nameWithOwner,parent" ],
          "registry fork lookup"
        )
        validate_fork_data!(data, repository, parent, owner)
        true
      end

      def pull_requests(repository)
        data = json!(
          [ "gh", "api", "--paginate", "--slurp",
            "repos/#{repository}/pulls?state=all&per_page=100" ],
          "registry pull-request lookup"
        )
        raise PublishOfflineError, "registry pull-request lookup returned invalid data" unless data.is_a?(Array)

        entries = data.all? { |page| page.is_a?(Array) } ? data.flatten(1) : data
        entries.map { |entry| pull_request(normalize_pull_request_entry(entry)) }
      end

      def commit_parent_oid(repository, oid)
        validate_repository!(repository)
        raise PublishRecoveryError, "publication commit identity is malformed" unless SHA.match?(oid.to_s)

        data = json!(
          [ "gh", "api", "repos/#{repository}/git/commits/#{oid}" ],
          "registry commit lookup"
        )
        parents = data.is_a?(Hash) ? data["parents"] : nil
        parent = parents.one? && parents.first.is_a?(Hash) ? parents.first["sha"].to_s.downcase : ""
        unless SHA.match?(parent)
          raise PublishRecoveryError, "registry publication commit must have one verified parent"
        end
        parent
      end

      def version_present?(repository, ref, package)
        path = "packages/#{package.name}/#{package.version}/manifest.yml"
        bytes = content_optional(repository, ref, path)
        return nil unless bytes

        manifest = Tempfile.create([ "hive-registry-manifest-", ".yml" ]) do |file|
          file.binmode
          file.write(bytes)
          file.flush
          RegistryManifest.load(file.path)
        end
        {
          package_digest: ::Digest::SHA256.hexdigest(bytes),
          release_digest: manifest.data.fetch("release_sha256")
        }
      rescue PackageError, KeyError
        raise PublishConflict, "registry contains malformed immutable package evidence"
      end

      def verify_remote_package!(repository, ref, package)
        identity = version_present?(repository, ref, package)
        unless identity && identity[:package_digest] == package.package_digest &&
               identity[:release_digest] == package.release_digest
          raise PublishConflict, "remote package bytes do not match the validated release"
        end
        verify_remote_tree!(repository, ref, package)
        true
      end

      def branch_oid(repository, branch)
        validate_repository!(repository)
        out = run!([ "git", "ls-remote", "--heads", "https://github.com/#{repository}.git",
                     "refs/heads/#{branch}" ], "registry branch lookup")
        lines = out.lines.map(&:strip).reject(&:empty?)
        return nil if lines.empty?
        oid, ref = lines.one? ? lines.first.split(/\s+/, 2) : []
        unless SHA.match?(oid.to_s.downcase) && ref == "refs/heads/#{branch}"
          raise PublishOfflineError, "registry branch lookup returned invalid data"
        end
        oid.downcase
      end

      def prepare_commit(package, repository:, base_branch:, base_oid:, head_repository:, branch:)
        key = ::Digest::SHA256.hexdigest([ repository, package.name, package.version, package.release_digest ].join("\0"))
        checkout = File.join(@objects_root, key)
        FileUtils.mkdir_p(@objects_root, mode: 0o700)
        File.chmod(0o700, @objects_root)
        if File.directory?(File.join(checkout, ".git"))
          oid = git!(checkout, "rev-parse", "HEAD").strip
          retained_branch = git!(checkout, "rev-parse", "refs/heads/#{branch}").strip
          parent = git!(checkout, "rev-parse", "#{oid}^").strip
          unless SHA.match?(oid) && oid == retained_branch && parent == base_oid
            raise PublishRecoveryError, "retained publication commit is inconsistent"
          end
          verify_commit_tree!(checkout, oid, package)
          git!(checkout, "remote", "set-url", "origin", "https://github.com/#{head_repository}.git")
          return [ checkout, oid ]
        end

        raise PublishRecoveryError, "retained publication object path is not a repository" if File.exist?(checkout)
        run!([ "git", "clone", "--quiet", "--no-checkout", "--no-tags", "--branch", base_branch, "--single-branch",
               "--", "https://github.com/#{repository}.git", checkout ], "registry clone")
        git!(checkout, "cat-file", "-e", "#{base_oid}^{commit}")
        git!(checkout, "checkout", "--quiet", "--detach", base_oid)
        actual_base = git!(checkout, "rev-parse", "HEAD").strip
        raise PublishRecoveryError, "recorded registry base is unavailable" unless actual_base == base_oid

        target = File.join(checkout, package.registry_path)
        raise PublishConflict, "immutable package version already exists" if File.exist?(target)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(package.root, target)
        git!(checkout, "checkout", "-b", branch)
        git!(checkout, "add", "--", package.registry_path)
        status = git!(checkout, "status", "--porcelain=v1").lines.map(&:strip).reject(&:empty?)
        unless status.any? && status.all? { |line| line.split.last.start_with?(package.registry_path) }
          raise PublishRecoveryError, "publication commit contains files outside the immutable package path"
        end
        git!(checkout, "-c", "user.name=Hive Workflow Publisher", "-c", "user.email=hive@users.noreply.github.com",
             "commit", "--quiet", "-m", "workflow: publish #{package.name} #{package.version}")
        oid = git!(checkout, "rev-parse", "HEAD").strip
        raise PublishRecoveryError, "publication commit identity is invalid" unless SHA.match?(oid)
        verify_commit_tree!(checkout, oid, package)
        git!(checkout, "remote", "set-url", "origin", "https://github.com/#{head_repository}.git")
        [ checkout, oid ]
      rescue SystemCallError, IOError => e
        raise PublishRecoveryError, "publication commit could not be retained: #{e.class}"
      end

      def push_expected_absent(checkout, branch, oid)
        ref = "refs/heads/#{branch}"
        _out, _err, status = run(
          [ "git", "-C", checkout, "push", "--force-with-lease=#{ref}:",
            "origin", "#{oid}:#{ref}" ]
        )
        raise PublishAmbiguousError, "registry branch push outcome is unknown" unless status.success?
        true
      end

      def cleanup_commit(package, repository:)
        key = ::Digest::SHA256.hexdigest(
          [ repository, package.name, package.version, package.release_digest ].join("\0")
        )
        checkout = File.join(@objects_root, key)
        return false unless File.exist?(checkout) || File.symlink?(checkout)

        root = File.lstat(@objects_root)
        target = File.lstat(checkout)
        unless root.directory? && !root.symlink? && root.uid == Process.uid &&
               (root.mode & 0o077).zero? && target.directory? && !target.symlink?
          raise PublishRecoveryError, "retained publication object path is unsafe to clean"
        end
        FileUtils.remove_entry_secure(checkout)
        true
      rescue SystemCallError, IOError
        raise PublishRecoveryError, "retained publication object cleanup failed"
      end

      def create_pull_request(repository:, base_branch:, head_repository:, branch:, package:)
        head_owner = head_repository.split("/", 2).first
        Tempfile.create([ "hive-workflow-publish-", ".md" ]) do |file|
          file.write(self.class.pr_body(package))
          file.flush
          out = run!(
            [ "gh", "pr", "create", "--repo", repository, "--base", base_branch,
              "--head", "#{head_owner}:#{branch}", "--title", "workflow: publish #{package.name} #{package.version}",
              "--body-file", file.path ],
            "registry pull-request creation", error: PublishAmbiguousError
          )
          url = out.lines.map(&:strip).find { |line| PR_URL.match?(line) }
          raise PublishAmbiguousError, "registry pull-request outcome is unknown" unless url
          url
        end
      end

      def self.pr_body(package)
        metadata = JSON.generate(
          "name" => package.name, "version" => package.version,
          "package_digest" => package.package_digest, "release_digest" => package.release_digest,
          "lint_contract" => package.lint_contract
        )
        findings = package.findings.map { |finding| "- `#{finding.fetch('rule_id')}` at `#{finding.fetch('path')}`" }
        findings = [ "- None" ] if findings.empty?
        <<~MARKDOWN
          <!-- hive-workflow-publish:v1 #{metadata} -->
          ## Honeycomb workflow package

          Package: `#{package.name}@#{package.version}`
          Package SHA-256: `#{package.package_digest}`
          Release SHA-256: `#{package.release_digest}`

          This non-draft submission adds only the immutable package version. Registry review, merge, and catalogue listing remain maintainer actions.

          Predecessor work: asterio/hive#705 and asterio/hive#751.

          ### Local findings

          #{findings.join("\n")}
        MARKDOWN
      end

      private

      def pull_request(entry)
        repository = entry.dig("headRepository", "nameWithOwner").to_s
        oid = entry["headRefOid"].to_s.downcase
        unless entry.is_a?(Hash) && entry["number"].is_a?(Integer) && PR_URL.match?(entry["url"].to_s) &&
               %w[OPEN CLOSED MERGED].include?(entry["state"]) && REPOSITORY.match?(repository) &&
               SHA.match?(oid) &&
               [ true, false ].include?(entry["isDraft"]) &&
               PublishReceipt::BRANCH.match?(entry["headRefName"].to_s) &&
               PublishReceipt::BRANCH.match?(entry["baseRefName"].to_s)
          raise PublishOfflineError, "registry pull-request lookup returned malformed evidence"
        end
        PullRequest.new(
          number: entry["number"], url: entry["url"], state: entry["state"], draft: entry["isDraft"],
          merged_at: entry["mergedAt"], head_repository: repository, head_branch: entry["headRefName"].to_s,
          head_oid: oid, base_branch: entry["baseRefName"].to_s, body: entry["body"].to_s
        ).freeze
      end

      def normalize_pull_request_entry(entry)
        return entry unless entry.is_a?(Hash) && entry.key?("html_url")

        state = entry["merged_at"] ? "MERGED" : entry["state"].to_s.upcase
        {
          "number" => entry["number"], "url" => entry["html_url"], "state" => state,
          "isDraft" => entry["draft"], "mergedAt" => entry["merged_at"],
          "headRepository" => { "nameWithOwner" => entry.dig("head", "repo", "full_name") },
          "headRefName" => entry.dig("head", "ref"), "headRefOid" => entry.dig("head", "sha"),
          "baseRefName" => entry.dig("base", "ref"), "body" => entry["body"]
        }
      end

      def validate_fork_data!(data, repository, parent, owner)
        expected_owner = repository.split("/", 2).first
        unless data.is_a?(Hash) && data["nameWithOwner"] == repository &&
               data.dig("parent", "nameWithOwner") == parent && expected_owner == owner
          raise PublishConflict, "configured fork identity does not match the registry"
        end
      end

      def content_optional(repository, ref, path)
        out, err, status = run(
          [ "gh", "api", "-H", "Accept: application/vnd.github.raw+json",
            "repos/#{repository}/contents/#{path}?ref=#{escape(ref)}" ]
        )
        return out.b if status.success?
        return nil if err.to_s.match?(/\b404\b|Not Found/i)
        raise PublishOfflineError, "registry package lookup failed"
      end

      def verify_remote_tree!(repository, ref, package)
        data = json!(
          [ "gh", "api", "repos/#{repository}/git/trees/#{escape(ref)}?recursive=1" ],
          "registry package tree lookup"
        )
        unless data.is_a?(Hash) && data["tree"].is_a?(Array) && data["truncated"] != true
          raise PublishOfflineError, "registry package tree lookup returned incomplete data"
        end
        prefix = "#{package.registry_path}/"
        actual = data.fetch("tree").filter_map do |entry|
          path = entry["path"].to_s
          next unless path.start_with?(prefix)
          unless entry["type"] == "blob" && %w[100644 100755].include?(entry["mode"]) &&
                 SHA.match?(entry["sha"].to_s)
            raise PublishConflict, "remote package tree contains a linked or special entry"
          end
          {
            path: path.delete_prefix(prefix), mode: entry["mode"],
            oid: entry["sha"].downcase
          }
        end.sort_by { |entry| entry.fetch(:path) }
        expected = expected_git_tree(package)
        raise PublishConflict, "remote package tree does not match the complete package inventory" unless actual == expected
      end

      def verify_commit_tree!(checkout, oid, package)
        changed = git!(
          checkout, "diff-tree", "--no-commit-id", "--name-only", "-r", oid
        ).lines.map(&:strip).reject(&:empty?).sort
        expected = expected_git_tree(package).map do |entry|
          "#{package.registry_path}/#{entry.fetch(:path)}"
        end
        unless changed == expected
          raise PublishRecoveryError, "publication commit changes files outside the immutable package"
        end

        tree = git!(checkout, "ls-tree", "-r", oid, "--", package.registry_path)
        actual = tree.lines.filter_map do |line|
          match = /\A(100644|100755) blob ([0-9a-f]{40})\t(.+)\z/.match(line.strip)
          unless match
            raise PublishRecoveryError, "publication commit tree is malformed"
          end
          {
            path: match[3].delete_prefix("#{package.registry_path}/"),
            mode: match[1], oid: match[2]
          }
        end.sort_by { |entry| entry.fetch(:path) }
        unless actual == expected_git_tree(package)
          raise PublishRecoveryError, "retained publication commit tree does not match the validated package"
        end
      end

      def expected_git_tree(package)
        Manifest.inventory(package.root, exclude: [], require_utf8: false).map do |entry|
          path = entry.fetch("path")
          bytes, stat = SafeFile.read(
            File.join(package.root, path), max_bytes: Manifest::MAX_FILE_BYTES,
            error_class: PublishRecoveryError,
            message: "validated package changed while deriving its commit tree"
          )
          {
            path: path, mode: (stat.mode & 0o111).positive? ? "100755" : "100644",
            oid: ::Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")
          }
        end.sort_by { |entry| entry.fetch(:path) }
      rescue PackageError
        raise PublishRecoveryError, "validated package tree is unavailable"
      end

      def git!(checkout, *args)
        run!([ "git", "-C", checkout, *args ], "publication git operation")
      end

      def json!(args, label, error: PublishOfflineError)
        JSON.parse(run!(args, label, error: error))
      rescue JSON::ParserError
        raise error, "#{label} returned invalid data"
      end

      def json_optional(args)
        out, err, status = run(args)
        return nil if !status.success? && err.to_s.match?(/\b404\b|Not Found/i)
        raise PublishOfflineError, "registry lookup failed" unless status.success?
        JSON.parse(out)
      rescue JSON::ParserError
        raise PublishOfflineError, "registry lookup returned invalid data"
      end

      def run!(args, label, error: PublishOfflineError)
        out, _err, status = run(args)
        raise error, "#{label} failed" unless status.success?
        out
      end

      def run(args)
        @runner.call(args, chdir: nil)
      rescue Hive::GhError, SystemCallError, IOError
        raise PublishOfflineError, "registry transport is unavailable"
      end

      def escape(value) = URI.encode_www_form_component(value.to_s)

      def validate_repository!(repository)
        raise Hive::ConfigError, "Honeycomb registry repository must be owner/name" unless REPOSITORY.match?(repository.to_s)
      end
    end
  end
end
