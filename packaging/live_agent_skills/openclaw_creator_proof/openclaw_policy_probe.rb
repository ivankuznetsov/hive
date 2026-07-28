module HiveLiveAgentProof
  module OpenClawCreatorProof
    class OpenClawPolicyProbe
      EFFECTIVE_TOOLS = %w[apply_patch edit exec read write].freeze
      PUBLIC_EXPORTS = {
        "config_schema" => "openclaw/plugin-sdk/config-schema",
        "agent_harness" => "openclaw/plugin-sdk/agent-harness"
      }.freeze
      DENIED_CONTROL_IDS = %w[
        outside_write outside_edit outside_apply_patch exec_absolute_touch
        exec_redirection exec_chained_touch prohibited_web_fetch
      ].freeze
      DRIVER_SOURCE_PATH = WORKFLOW_CREATOR_DRIVER_PATH

      attr_reader :authoring_receipt_path, :driver_path, :receipt_path

      def initialize(root:, openclaw:, configuration:, process_runner:, document:,
                     revalidate:)
        @root = File.expand_path(root)
        @openclaw = openclaw
        @configuration = configuration
        @process_runner = process_runner
        @document = document
        @revalidate = revalidate
        @receipt_path = File.join(@root, "effects", "openclaw-policy.json")
        @authoring_receipt_path =
          File.join(@root, "effects", "openclaw-native-authoring.json")
        @driver_path = File.join(@root, "effects", "openclaw-native-tools.mjs")
      end

      def call(environment:, workspace:)
        materialize_driver!
        @revalidate.call
        result = @process_runner.call(
          environment: environment,
          argv: driver_argv("probe", workspace),
          chdir: workspace,
          timeout: 45
        )
        @revalidate.call
        @document.record_process(result, label: "native_tool_surface")
        unless result.fetch("status")&.success? &&
               result.dig("record", "teardown", "status") == "passed" &&
               result.fetch("secret_findings").empty?
          fail_policy!("exact OpenClaw native-tool probe failed")
        end
        payload = typed_payload(result.fetch("stdout"), "hive-openclaw-effective-policy")
        fail_policy!("exact OpenClaw native-tool probe emitted no typed receipt") unless payload

        validate!(payload, workspace)
        HiveLiveAgentProof.write_json(@receipt_path, payload)
        payload
      rescue JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => e
        fail_policy!("cannot retain exact OpenClaw native-tool policy: #{e.message}")
      end

      def driver_environment(workspace:)
        materialize_driver!
        {
          "HIVE_OPENCLAW_NATIVE_TOOL_NODE" =>
            @openclaw.fetch("interpreter").fetch("realpath"),
          "HIVE_OPENCLAW_NATIVE_TOOL_DRIVER" => @driver_path,
          "HIVE_OPENCLAW_NATIVE_TOOL_INSTALL_ROOT" =>
            @openclaw.fetch("install_root"),
          "HIVE_OPENCLAW_NATIVE_TOOL_CONFIG" => @configuration.config_path,
          "HIVE_OPENCLAW_NATIVE_TOOL_APPROVALS" => @configuration.approvals_path,
          "HIVE_OPENCLAW_NATIVE_TOOL_WORKSPACE" => File.realpath(workspace),
          "HIVE_OPENCLAW_NATIVE_TOOL_AUTHORING_RECEIPT" =>
            @authoring_receipt_path,
          "HIVE_OPENCLAW_NATIVE_TOOL_EXPECTED_VERSION" => OPENCLAW_VERSION
        }
      end

      private

      def materialize_driver!
        source_stat = File.lstat(DRIVER_SOURCE_PATH)
        unless source_stat.file? && !source_stat.symlink?
          fail_policy!("committed native-tool driver is not a regular file")
        end
        source = File.realpath(DRIVER_SOURCE_PATH)
        source_digest = WORKFLOW_CREATOR_DRIVER_SHA256
        if File.exist?(@driver_path)
          valid = File.file?(@driver_path) && !File.symlink?(@driver_path) &&
                  Digest::SHA256.file(@driver_path).hexdigest == source_digest
          fail_policy!("materialized native-tool driver identity changed") unless valid
          return
        end

        FileUtils.mkdir_p(File.dirname(@driver_path), mode: 0o700)
        File.open(@driver_path, File::WRONLY | File::CREAT | File::EXCL, 0o400) do |file|
          File.open(source, "rb") { |input| IO.copy_stream(input, file) }
          file.flush
          file.fsync
        end
        fail_policy!("materialized native-tool driver digest changed") unless
          Digest::SHA256.file(@driver_path).hexdigest == source_digest
      rescue Errno::EEXIST
        retry
      end

      def driver_argv(mode, workspace, *extra)
        [
          @openclaw.fetch("interpreter").fetch("realpath"),
          @driver_path,
          mode,
          @openclaw.fetch("install_root"),
          @configuration.config_path,
          @configuration.approvals_path,
          File.realpath(workspace),
          "-",
          OPENCLAW_VERSION,
          *extra
        ]
      end

      def typed_payload(output, schema)
        output.to_s.scrub.lines.reverse_each.filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end.find { |row| row.is_a?(Hash) && row["schema"] == schema }
      end

      def validate!(payload, workspace)
        required = %w[
          apply_patch_workspace_only driver_sha256 effective_tools elevated_enabled
          exec_allowlist monitored_surfaces outside_read_caveat proof_mode
          public_exports runtime_package schema schema_version source tool_receipts
          unauthorized_effects_observed workspace workspace_only
        ]
        receipts = payload["tool_receipts"]
        by_id = receipts.to_a.to_h { |row| [ row["id"], row ] }
        gateway = File.join(@configuration.gateway_bin_dir, "hive")
        successful = %w[
          inside_write inside_read inside_edit inside_apply_patch exec_hive_version
        ]
        valid = payload.is_a?(Hash) && payload.keys.sort == required.sort &&
                payload["schema"] == "hive-openclaw-effective-policy" &&
                payload["schema_version"] == 2 &&
                %w[openclaw-exact-runtime public-export-contract-fixture].include?(
                  payload["source"]
                ) &&
                payload["driver_sha256"] == WORKFLOW_CREATOR_DRIVER_SHA256 &&
                payload["workspace"] == File.realpath(workspace) &&
                payload["effective_tools"] == EFFECTIVE_TOOLS &&
                payload["workspace_only"] == true &&
                payload["apply_patch_workspace_only"] == true &&
                payload["elevated_enabled"] == false &&
                payload["proof_mode"] == "direct_native_tool_surface" &&
                payload["public_exports"] == PUBLIC_EXPORTS &&
                payload.dig("runtime_package", "name") == "openclaw" &&
                payload.dig("runtime_package", "version") == OPENCLAW_VERSION &&
                payload["exec_allowlist"] == [ gateway ] &&
                payload["unauthorized_effects_observed"] == [] &&
                payload["monitored_surfaces"].is_a?(Array) &&
                payload["outside_read_caveat"].is_a?(Hash) &&
                payload["outside_read_caveat"].keys.sort ==
                  %w[caveat global_denial_claimed ordinary_sibling_decision] &&
                payload.dig("outside_read_caveat", "caveat") ==
                  WORKFLOW_CREATOR_OUTSIDE_READ_CAVEAT &&
                payload.dig("outside_read_caveat", "global_denial_claimed") == false &&
                receipts.is_a?(Array) &&
                receipts.map { |row| row["id"] }.uniq.length == receipts.length &&
                successful.all? { |id| by_id.dig(id, "decision") == "succeeded" } &&
                DENIED_CONTROL_IDS.all? {
                  |id| by_id.dig(id, "decision") == "denied" &&
                    by_id.dig(id, "mutation_observed") == false
                }
        fail_policy!("OpenClaw native-tool policy differs from the accepted surface") unless valid
      end

      def fail_policy!(detail)
        raise Failure.new(
          phase: "configuration",
          reason: "effective_policy_invalid",
          detail: detail
        )
      end
    end
  end
end
