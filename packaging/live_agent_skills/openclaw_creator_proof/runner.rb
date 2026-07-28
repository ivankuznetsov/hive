module HiveLiveAgentProof
  module OpenClawCreatorProof
    class Runner
      PROCESS_TIMEOUT = 240
      PROCESS_TERM_GRACE = 5
      PROCESS_OUTPUT_LIMIT = 128 * 1024

      attr_reader :evidence

      def self.from_env(environment = ENV)
        new(
          candidate_sha: environment["HIVE_CANDIDATE_SHA"],
          artifact_dir: environment["HIVE_PROOF_ARTIFACTS"],
          evidence_path: environment["HIVE_CREATOR_EVIDENCE_PATH"],
          model: environment["HIVE_LIVE_MODEL"],
          provider_credential: environment["HIVE_LIVE_PROVIDER_CREDENTIAL"],
          proven_hive_bin: environment["HIVE_PROVEN_HIVE_BIN"],
          openclaw_bin: environment["HIVE_OPENCLAW_BIN"],
          openclaw_package_version: environment["HIVE_OPENCLAW_PACKAGE_VERSION"],
          openclaw_package_integrity: environment["HIVE_OPENCLAW_PACKAGE_INTEGRITY"],
          base_environment: environment
        )
      end

      def initialize(candidate_sha:, artifact_dir:, evidence_path:, model:,
                     provider_credential:, proven_hive_bin:, openclaw_bin: nil,
                     openclaw_package_version: nil, openclaw_package_integrity: nil,
                     base_environment: ENV,
                     root_factory: -> { Dir.mktmpdir("hive-openclaw-creator-proof") },
                     cleanup: ->(root) { FileUtils.rm_rf(root) },
                     process_runner_factory: nil)
        @candidate_sha = candidate_sha.to_s.downcase
        @artifact_dir = artifact_dir.to_s
        @evidence_path = evidence_path.to_s
        @model = model.to_s
        @provider_credential = provider_credential.to_s
        @proven_hive_bin = proven_hive_bin.to_s
        @openclaw_bin = openclaw_bin.to_s
        @openclaw_package_version = openclaw_package_version.to_s
        @openclaw_package_integrity = openclaw_package_integrity.to_s
        @base_environment = base_environment.to_h.transform_keys(&:to_s)
        @root_factory = root_factory
        @cleanup = cleanup
        @process_runner_factory = process_runner_factory || method(:build_process_runner)
        @root = nil
        @environment_policy = EnvironmentPolicy.new(
          model: @model,
          credential: @provider_credential,
          base_environment: @base_environment
        )
        @document = EvidenceDocument.new(
          candidate_sha: @candidate_sha,
          model: @model,
          candidate_path: @proven_hive_bin,
          openclaw_path: @openclaw_bin,
          credential: @provider_credential
        )
        @evidence = @document.data
      end

      def call
        execute
      rescue Failure => e
        record_failure(e)
      rescue StandardError => e
        record_failure(
          Failure.new(
            phase: @evidence["phase"],
            reason: "unexpected_error",
            detail: "#{e.class}: #{e.message}"
          )
        )
      ensure
        @document.finalize_teardown
        cleanup_root
        @document.finalize_secret_scan
        @document.write(@evidence_path)
      end

      def provider = @environment_policy.provider

      def child_environment(additions = {}) = @environment_policy.child_environment(additions)

      private

      def execute
        @document.phase = "preflight"
        @document.provider = provider
        validate_preflight!
        candidate = resolve_executable!(
          @proven_hive_bin, kind: "candidate", search_path: false
        )
        openclaw = resolve_executable!(
          @openclaw_bin, kind: "openclaw", search_path: true
        )
        @document.set_executable("candidate", candidate)
        @document.set_executable("openclaw", openclaw)
        validate_artifact_directory!
        git = resolve_executable!("", kind: "git", search_path: true)

        @root = File.expand_path(@root_factory.call.to_s)
        unless File.directory?(@root) && !File.symlink?(@root) && Dir.empty?(@root)
          fail_with!("setup", "proof_root_invalid", "proof root is not a fresh directory")
        end
        FileUtils.chmod(0o700, @root)
        root_sentinel = File.join(@root, ".hive-openclaw-creator-proof-root")
        File.open(root_sentinel, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("owned\n")
        end
        process_runner = @process_runner_factory.call
        ProofExecutor.new(
          root: @root,
          candidate: candidate,
          openclaw: openclaw,
          git: git,
          candidate_sha: @candidate_sha,
          artifact_dir: @artifact_dir,
          model: @model,
          environment_policy: @environment_policy,
          document: @document,
          process_runner: process_runner
        ).call
      end

      def build_process_runner
        ProcessRunner.new(
          timeout: PROCESS_TIMEOUT,
          term_grace: PROCESS_TERM_GRACE,
          output_limit: PROCESS_OUTPUT_LIMIT,
          exact_secrets: [ @provider_credential ]
        )
      end

      def validate_preflight!
        unless SAFE_SHA.match?(@candidate_sha)
          fail_with!(
            "preflight", "invalid_candidate_sha",
            "invalid candidate SHA #{@candidate_sha.inspect}"
          )
        end
        if @provider_credential.empty?
          fail_with!(
            "preflight", "missing_provider_credential",
            "HIVE_LIVE_PROVIDER_CREDENTIAL is required"
          )
        end
        if @provider_credential.bytesize > CREDENTIAL_LIMIT
          fail_with!(
            "preflight", "invalid_provider_credential",
            "HIVE_LIVE_PROVIDER_CREDENTIAL exceeds #{CREDENTIAL_LIMIT} bytes"
          )
        end
        validate_openclaw_package!
        if @evidence_path.empty?
          fail_with!(
            "preflight", "missing_evidence_path",
            "HIVE_CREATOR_EVIDENCE_PATH is required"
          )
        end
      end

      def validate_openclaw_package!
        if @openclaw_package_version.empty?
          fail_with!(
            "preflight", "missing_openclaw_package_version",
            "HIVE_OPENCLAW_PACKAGE_VERSION is required"
          )
        end
        unless @openclaw_package_version == OPENCLAW_VERSION
          fail_with!(
            "preflight", "openclaw_package_version_mismatch",
            "OpenClaw package version does not match the pinned proof version"
          )
        end
        if @openclaw_package_integrity.empty?
          fail_with!(
            "preflight", "missing_openclaw_package_integrity",
            "HIVE_OPENCLAW_PACKAGE_INTEGRITY is required"
          )
        end
        unless @openclaw_package_integrity == OPENCLAW_INTEGRITY
          fail_with!(
            "preflight", "openclaw_package_integrity_mismatch",
            "OpenClaw package integrity does not match the pinned proof integrity"
          )
        end

        @document.openclaw_package_verified!
      end

      def validate_artifact_directory!
        unless File.directory?(@artifact_dir) && !File.symlink?(@artifact_dir)
          fail_with!(
            "preflight", "artifact_directory_missing",
            "HIVE_PROOF_ARTIFACTS is not a regular directory: #{@artifact_dir}"
          )
        end
      end

      def resolve_executable!(configured, kind:, search_path:)
        path = configured.to_s
        path = find_on_path(kind) if path.empty? && search_path
        reason = "#{kind}_not_executable"
        unless !path.to_s.empty? && Pathname.new(path).absolute? &&
               File.file?(path) && File.executable?(path)
          fail_with!(
            "preflight", reason,
            "#{kind} executable is unavailable: #{path.to_s.empty? ? '(unset)' : path}"
          )
        end

        realpath = File.realpath(path)
        {
          "configured_path" => File.expand_path(path),
          "realpath" => realpath,
          "sha256" => Digest::SHA256.file(realpath).hexdigest
        }
      rescue Errno::EACCES, Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR => e
        fail_with!("preflight", reason, e.message)
      end

      def find_on_path(name)
        @base_environment.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          candidate = File.expand_path(File.join(directory, name))
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def record_failure(failure)
        @document.failure(failure)
      end

      def fail_with!(phase, reason, detail)
        raise Failure.new(phase: phase, reason: reason, detail: detail)
      end

      def cleanup_root
        if @root.nil?
          @document.cleanup = { "status" => "passed", "root_removed" => true }
          return
        end
        unsafe = @root == File::SEPARATOR || Pathname.new(@root).each_filename.to_a.length < 2
        fail_with!("cleanup", "unsafe_cleanup_root", "refusing unsafe cleanup root") if unsafe
        sentinel = File.join(@root, ".hive-openclaw-creator-proof-root")
        unless File.file?(sentinel) && !File.symlink?(sentinel) &&
               File.read(sentinel) == "owned\n"
          fail_with!("cleanup", "cleanup_ownership_missing", "proof root ownership is missing")
        end

        @cleanup.call(@root)
        removed = !File.exist?(@root)
        @document.cleanup = {
          "status" => removed ? "passed" : "failed",
          "root_removed" => removed
        }
        record_failure(
          Failure.new(
            phase: "cleanup",
            reason: "cleanup_incomplete",
            detail: "proof root remains after cleanup"
          )
        ) unless removed
      rescue Failure => e
        @document.cleanup = { "status" => "failed", "root_removed" => false }
        record_failure(e)
      rescue StandardError => e
        @document.cleanup = { "status" => "failed", "root_removed" => false }
        record_failure(
          Failure.new(phase: "cleanup", reason: "cleanup_failed", detail: e.message)
        )
      end
    end
  end
end
