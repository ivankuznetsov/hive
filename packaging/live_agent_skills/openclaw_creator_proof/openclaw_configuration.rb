module HiveLiveAgentProof
  module OpenClawCreatorProof
    class OpenClawConfiguration
      attr_reader :config_path, :state_dir

      def initialize(root:, workspace:, model:, gateway_bin_dir:)
        @root = File.expand_path(root)
        @workspace = File.expand_path(workspace)
        @model = model.to_s
        @gateway_bin_dir = File.expand_path(gateway_bin_dir)
        @state_dir = File.join(@root, "openclaw-state")
        @config_path = File.join(@state_dir, "openclaw.json")
      end

      def write
        raise Failure.new(
          phase: "configuration",
          reason: "invalid_gateway_path",
          detail: "OpenClaw pathPrepend must be an existing directory"
        ) unless File.directory?(@gateway_bin_dir) && !File.symlink?(@gateway_bin_dir)

        FileUtils.mkdir_p(@state_dir, mode: 0o700)
        payload = {
          "agents" => {
            "defaults" => {
              "workspace" => @workspace,
              "model" => { "primary" => @model }
            }
          },
          "tools" => {
            "profile" => "coding",
            "exec" => { "pathPrepend" => [ @gateway_bin_dir ] }
          }
        }
        File.open(@config_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.pretty_generate(payload))
          file.write("\n")
        end
        payload
      rescue Errno::EACCES, Errno::ENOENT, Errno::EEXIST, Errno::ENOTDIR => e
        raise Failure.new(
          phase: "configuration",
          reason: "openclaw_configuration_failed",
          detail: e.message
        )
      end
    end
  end
end
