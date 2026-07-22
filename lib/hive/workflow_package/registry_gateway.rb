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
            parent = data.dig("parent", "nameWithOwner")
            unless data["nameWithOwner"] == fork && parent == repository
              raise PublishConflict, "configured fork identity does not match the registry"
            end
            return fork
          end
          run!([ "gh", "repo", "fork", repository, "--clone=false", "--remote=false" ], "registry fork creation") if attempt.zero?
          @sleeper.call(1) unless attempt == 9
        end
        raise PublishAmbiguousError, "registry fork outcome is unknown"
      end

      def pull_requests(repository)
        fields = "number,url,state,isDraft,mergedAt,headRepository,headRefName,headRefOid,baseRefName,body"
        data = json!(
          [ "gh", "pr", "list", "--repo", repository, "--state", "all", "--limit", "100", "--json", fields ],
          "registry pull-request lookup"
        )
        raise PublishOfflineError, "registry pull-request lookup returned invalid data" unless data.is_a?(Array)

        data.map { |entry| pull_request(entry) }
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
          retained_branch = git!(checkout, "rev-parse", branch).strip
          return [ checkout, oid ] if SHA.match?(oid) && oid == retained_branch
          raise PublishRecoveryError, "retained publication commit is inconsistent"
        end

        raise PublishRecoveryError, "retained publication object path is not a repository" if File.exist?(checkout)
        run!([ "git", "clone", "--quiet", "--no-tags", "--branch", base_branch, "--single-branch",
               "--", "https://github.com/#{repository}.git", checkout ], "registry clone")
        actual_base = git!(checkout, "rev-parse", "HEAD").strip
        raise PublishConflict, "registry base moved during package preparation" unless actual_base == base_oid

        target = File.join(checkout, package.registry_path)
        raise PublishConflict, "immutable package version already exists" if File.exist?(target)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(package.root, target)
        git!(checkout, "checkout", "-b", branch)
        git!(checkout, "add", "--", package.registry_path)
        status = git!(checkout, "status", "--porcelain=v1").lines.map(&:strip)
        unless status.any? && status.all? { |line| line.split.last.start_with?(package.registry_path) }
          raise PublishRecoveryError, "publication commit contains files outside the immutable package path"
        end
        git!(checkout, "-c", "user.name=Hive Workflow Publisher", "-c", "user.email=hive@users.noreply.github.com",
             "commit", "--quiet", "-m", "workflow: publish #{package.name} #{package.version}")
        oid = git!(checkout, "rev-parse", "HEAD").strip
        raise PublishRecoveryError, "publication commit identity is invalid" unless SHA.match?(oid)
        git!(checkout, "remote", "set-url", "origin", "https://github.com/#{head_repository}.git")
        [ checkout, oid ]
      rescue SystemCallError, IOError => e
        raise PublishRecoveryError, "publication commit could not be retained: #{e.class}"
      end

      def push_expected_absent(checkout, branch, oid)
        _out, _err, status = run([ "git", "-C", checkout, "push", "origin", "#{oid}:refs/heads/#{branch}" ])
        raise PublishAmbiguousError, "registry branch push outcome is unknown" unless status.success?
        true
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
               %w[OPEN CLOSED MERGED].include?(entry["state"]) && REPOSITORY.match?(repository) && SHA.match?(oid)
          raise PublishOfflineError, "registry pull-request lookup returned malformed evidence"
        end
        PullRequest.new(
          number: entry["number"], url: entry["url"], state: entry["state"], draft: entry["isDraft"] != false,
          merged_at: entry["mergedAt"], head_repository: repository, head_branch: entry["headRefName"].to_s,
          head_oid: oid, base_branch: entry["baseRefName"].to_s, body: entry["body"].to_s
        ).freeze
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
          unless entry["type"] == "blob" && %w[100644 100755].include?(entry["mode"])
            raise PublishConflict, "remote package tree contains a linked or special entry"
          end
          path.delete_prefix(prefix)
        end.sort
        expected = Manifest.inventory(package.root, exclude: [], require_utf8: false).keys.sort
        raise PublishConflict, "remote package tree does not match the complete package inventory" unless actual == expected
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
