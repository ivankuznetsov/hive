module HiveLiveAgentProof
  module OpenClawCreatorProof
    class AuditGateway
      RUNTIME_DIRECTORY = File.expand_path("gateway_runtime", __dir__).freeze
      RUNTIME_FILES = %w[
        attempt_ledger.rb
        candidate_identity.rb
        candidate_executor.rb
        result_ledger.rb
        task_binding.rb
        main.rb
      ].freeze
      RUNTIME_SCHEMA = "hive-openclaw-audit-gateway-runtime".freeze
      RUNTIME_SCHEMA_VERSION = 1

      attr_reader :candidate_record, :gateway_record, :audit_path, :result_path

      def initialize(candidate_path:, directory:, audit_path:, commands: WORKFLOW_CREATOR_COMMANDS,
                     workspace: nil, result_path: nil, candidate_identity: nil)
        @configured_candidate = candidate_path.to_s
        @directory = File.expand_path(directory)
        @audit_path = File.expand_path(audit_path)
        @result_path = File.expand_path(result_path || "#{@audit_path}.results")
        @commands = commands.map { |argv| argv.map(&:to_s).freeze }.freeze
        @workspace = workspace && File.expand_path(workspace)
        @candidate_identity = candidate_identity
      end

      def install
        validate_candidate!
        validate_dynamic_binding!
        runtime_sources = load_runtime_sources!
        reject_existing_destination!

        bin_dir = File.join(@directory, "bin")
        runtime_dir = File.join(@directory, "runtime")
        FileUtils.mkdir_p([ bin_dir, runtime_dir ], mode: 0o700)
        runtime_records = materialize_runtime(runtime_dir, runtime_sources)
        config_path, config_digest = write_config(runtime_dir)
        launcher_path = File.join(bin_dir, "hive")
        write_launcher(
          launcher_path,
          runtime_dir: runtime_dir,
          runtime_records: runtime_records,
          config_path: config_path,
          config_digest: config_digest
        )
        @gateway_record = executable_record(launcher_path).merge(
          "runtime_bundle" => runtime_bundle_record(
            runtime_records, config_digest: config_digest
          )
        )
        launcher_path
      rescue Errno::EACCES, Errno::EEXIST, Errno::ENOENT, Errno::ENOTDIR => e
        raise Failure.new(
          phase: "gateway",
          reason: "gateway_install_failed",
          detail: e.message
        )
      end

      private

      def validate_candidate!
        unless Pathname.new(@configured_candidate).absolute?
          raise Failure.new(
            phase: "preflight",
            reason: "candidate_path_not_absolute",
            detail: "candidate receipt executable must be absolute"
          )
        end
        unless regular_executable?(@configured_candidate)
          raise Failure.new(
            phase: "preflight",
            reason: "candidate_not_executable",
            detail: "candidate receipt executable is unavailable: #{@configured_candidate}"
          )
        end

        @candidate_record = executable_record(@configured_candidate)
        return unless @candidate_identity
        return if %w[configured_path realpath sha256].all? {
          |key| @candidate_identity[key] == @candidate_record[key]
        } && @candidate_identity["receipt_path"].to_s.start_with?("/")

        raise Failure.new(
          phase: "preflight",
          reason: "candidate_installation_identity_invalid",
          detail: "candidate gateway identity is not bound to its installation receipt"
        )
      rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES => e
        raise Failure.new(
          phase: "preflight",
          reason: "candidate_not_executable",
          detail: e.message
        )
      end

      def validate_dynamic_binding!
        return unless @commands.include?([ "run", WORKFLOW_CREATOR_RUN_PLACEHOLDER ])
        return if @workspace && File.directory?(@workspace) && !File.symlink?(@workspace)

        raise Failure.new(
          phase: "gateway",
          reason: "dynamic_binding_unavailable",
          detail: "dynamic workflow-creator run binding requires a regular workspace"
        )
      end

      def reject_existing_destination!
        return unless File.exist?(@directory) || File.symlink?(@directory)

        raise Failure.new(
          phase: "gateway",
          reason: "gateway_destination_exists",
          detail: "audit gateway destination already exists: #{@directory}"
        )
      end

      def load_runtime_sources!
        RUNTIME_FILES.to_h do |name|
          path = File.join(RUNTIME_DIRECTORY, name)
          stat = File.lstat(path)
          unless stat.file? && !stat.symlink? &&
                 File.realpath(path).start_with?("#{File.realpath(RUNTIME_DIRECTORY)}/")
            raise Failure.new(
              phase: "gateway",
              reason: "gateway_runtime_source_invalid",
              detail: "gateway runtime source is not a committed regular file: #{name}"
            )
          end
          [ name, File.binread(path) ]
        end
      rescue SystemCallError => e
        raise Failure.new(
          phase: "gateway",
          reason: "gateway_runtime_source_invalid",
          detail: e.message
        )
      end

      def materialize_runtime(runtime_dir, sources)
        sources.map do |name, bytes|
          path = File.join(runtime_dir, name)
          write_exclusive(path, bytes, mode: 0o400)
          {
            "name" => name,
            "sha256" => Digest::SHA256.hexdigest(bytes)
          }
        end.freeze
      end

      def write_config(runtime_dir)
        path = File.join(runtime_dir, "config.json")
        bytes = "#{JSON.generate(runtime_config)}\n"
        write_exclusive(path, bytes, mode: 0o400)
        [ path, Digest::SHA256.hexdigest(bytes) ]
      end

      def runtime_config
        {
          "schema" => "hive-openclaw-audit-gateway-config",
          "schema_version" => 1,
          "candidate" => @candidate_record.fetch("realpath"),
          "expected_digest" => @candidate_record.fetch("sha256"),
          "commands" => @commands,
          "audit_path" => @audit_path,
          "result_path" => @result_path,
          "lock_path" => File.join(@directory, "audit.lock"),
          "workspace" => @workspace,
          "run_placeholder" => WORKFLOW_CREATOR_RUN_PLACEHOLDER,
          "task_key" => WORKFLOW_CREATOR_TASK_KEY,
          "task_workflow" => WORKFLOW_CREATOR_WORKFLOW,
          "safe_slug_pattern" => WORKFLOW_CREATOR_SAFE_SLUG.source,
          "credential_names" => (
            PROVIDER_CREDENTIAL_ENV.values + [ "HIVE_LIVE_PROVIDER_CREDENTIAL" ]
          ).uniq,
          "candidate_identity" => @candidate_identity
        }
      end

      def write_launcher(path, runtime_dir:, runtime_records:, config_path:, config_digest:)
        file_digests = runtime_records.to_h {
          |record| [ record.fetch("name"), record.fetch("sha256") ]
        }
        script = <<~RUBY
          #!#{RbConfig.ruby}
          require "digest"
          require "fileutils"
          require "json"
          require "open3"
          require "pathname"
          require "yaml"

          runtime_dir = #{runtime_dir.dump}
          config_path = #{config_path.dump}
          expected_config_digest = #{config_digest.dump}
          expected_runtime_digests = #{file_digests.inspect}

          def verified_regular_bytes(path, expected_digest)
            stat = File.lstat(path)
            raise "identity target is not a regular file: \#{path}" unless
              stat.file? && !stat.symlink?
            bytes = File.binread(path)
            raise "identity digest changed: \#{path}" unless
              Digest::SHA256.hexdigest(bytes) == expected_digest
            bytes
          end

          begin
            runtime_stat = File.lstat(runtime_dir)
            raise "runtime directory identity changed" unless
              runtime_stat.directory? && !runtime_stat.symlink?
            config = JSON.parse(
              verified_regular_bytes(config_path, expected_config_digest)
            )
            expected_runtime_digests.each do |name, digest|
              verified_regular_bytes(File.join(runtime_dir, name), digest)
            end
            expected_runtime_digests.each_key do |name|
              require File.join(runtime_dir, name.delete_suffix(".rb"))
            end
            exit HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::Main.call(
              config, ARGV
            )
          rescue StandardError => e
            warn "workflow-creator proof gateway runtime identity failed: " \
                 "\#{e.class}: \#{e.message}"
            exit 69
          end
        RUBY
        write_exclusive(path, script, mode: 0o500)
      end

      def write_exclusive(path, bytes, mode:)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
          written = file.write(bytes)
          raise Errno::EIO, "incomplete gateway write: #{path}" unless
            written == bytes.bytesize

          file.flush
          file.fsync
        end
        FileUtils.chmod(mode, path)
      end

      def runtime_bundle_record(runtime_records, config_digest:)
        manifest_payload = {
          "config_sha256" => config_digest,
          "files" => runtime_records
        }
        {
          "schema" => RUNTIME_SCHEMA,
          "schema_version" => RUNTIME_SCHEMA_VERSION,
          "config_sha256" => config_digest,
          "manifest_sha256" =>
            Digest::SHA256.hexdigest(JSON.generate(manifest_payload)),
          "files" => runtime_records
        }
      end

      def regular_executable?(path)
        stat = File.lstat(path)
        stat.file? && !stat.symlink? && File.executable?(path)
      rescue SystemCallError
        false
      end

      def executable_record(path)
        realpath = File.realpath(path)
        {
          "configured_path" => File.expand_path(path),
          "realpath" => realpath,
          "sha256" => Digest::SHA256.file(realpath).hexdigest
        }
      end
    end
  end
end
