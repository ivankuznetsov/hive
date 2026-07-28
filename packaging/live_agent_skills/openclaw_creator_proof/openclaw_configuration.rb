module HiveLiveAgentProof
  module OpenClawCreatorProof
    class OpenClawConfiguration
      attr_reader :approvals_path, :config_path, :gateway_bin_dir, :state_dir

      def initialize(root:, workspace:, model:, gateway_bin_dir:)
        @root = File.expand_path(root)
        @workspace = File.expand_path(workspace)
        @model = model.to_s
        @gateway_bin_dir = File.expand_path(gateway_bin_dir)
        @state_dir = File.join(@root, "openclaw-state")
        @config_path = File.join(@state_dir, "openclaw.json")
        @approvals_path = File.join(@state_dir, "exec-approvals.json")
      end

      def write
        raise Failure.new(
          phase: "configuration",
          reason: "invalid_gateway_path",
          detail: "OpenClaw pathPrepend must be an existing directory"
        ) unless File.directory?(@gateway_bin_dir) && !File.symlink?(@gateway_bin_dir)
        gateway_path = File.join(@gateway_bin_dir, "hive")
        unless File.file?(gateway_path) && !File.symlink?(gateway_path) &&
               File.executable?(gateway_path)
          raise Failure.new(
            phase: "configuration",
            reason: "invalid_gateway_path",
            detail: "OpenClaw audit gateway must be an executable regular file"
          )
        end

        FileUtils.mkdir_p(@state_dir, mode: 0o700)
        payload = {
          "agents" => {
            "defaults" => {
              "workspace" => @workspace,
              "model" => { "primary" => @model }
            }
          },
          "tools" => {
            "allow" => %w[read write edit apply_patch exec],
            "fs" => {
              "workspaceOnly" => true
            },
            "elevated" => {
              "enabled" => false
            },
            "exec" => {
              "mode" => "allowlist",
              "host" => "gateway",
              "strictInlineEval" => true,
              "applyPatch" => {
                "enabled" => true,
                "workspaceOnly" => true
              },
              "pathPrepend" => [ @gateway_bin_dir ]
            }
          }
        }
        secure_json_write(@config_path, payload)
        secure_json_write(@approvals_path, approvals(gateway_path))
        payload
      rescue Errno::EACCES, Errno::ENOENT, Errno::EEXIST, Errno::ENOTDIR => e
        raise Failure.new(
          phase: "configuration",
          reason: "openclaw_configuration_failed",
          detail: e.message
        )
      end

      private

      def approvals(gateway_path)
        {
          "version" => 1,
          "defaults" => {
            "security" => "deny",
            "ask" => "off",
            "askFallback" => "deny",
            "autoAllowSkills" => false
          },
          "agents" => {
            "main" => {
              "security" => "allowlist",
              "ask" => "off",
              "askFallback" => "deny",
              "autoAllowSkills" => false,
              "allowlist" => [
                {
                  "id" => Digest::SHA256.hexdigest(gateway_path),
                  "pattern" => gateway_path
                }
              ]
            }
          }
        }
      end

      def secure_json_write(path, value)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.pretty_generate(value))
          file.write("\n")
        end
      end
    end
  end
end
