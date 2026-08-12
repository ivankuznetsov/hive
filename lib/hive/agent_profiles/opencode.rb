require "json"

require "hive/agent_profile"
require "hive/skill_check"

module Hive
  module AgentProfiles
    module OpenCodeDefaults
      module_function

      def resolve(cfg:, project_root: nil, **)
        inline = cfg&.dig("agents", "opencode", "config")
        if inline
          unless inline.is_a?(Hash)
            raise Hive::ImplementationIdentity::ResolutionError,
                  "agents.opencode.config must be a JSON object"
          end
          return AgentCliRuntime::Route.parse(inline["model"]).to_s
        end

        path = cfg&.dig("agents", "opencode", "config_path").to_s
        unless path.empty? || File.absolute_path?(path)
          path = File.expand_path(path, project_root || cfg["project_root"])
        end
        if path.empty?
          raise Hive::ImplementationIdentity::ResolutionError,
                "OpenCode requires models.<role>.model or an explicit " \
                "agents.opencode.config_path default"
        end

        document = JSON.parse(File.binread(path))
        unless document.is_a?(Hash)
          raise Hive::ImplementationIdentity::ResolutionError,
                "OpenCode selected configuration must be a JSON object"
        end
        AgentCliRuntime::Route.parse(document["model"]).to_s
      rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, ArgumentError => e
        raise Hive::ImplementationIdentity::ResolutionError,
              "could not inspect explicit OpenCode default model: #{e.message}"
      end
    end

    OPENCODE = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:opencode),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :output_file_exists,
      permission_presets: %w[read-only scoped],
      skill_verifier: Hive::SkillCheck::OpenCode.method(:verify),
      default_model_resolver: OpenCodeDefaults.method(:resolve),
      routed_model_argument_builder: lambda { |model|
        AgentCliRuntime::Profiles.opencode_model_arguments(model)
      },
      routed_effort_argument_builder: lambda { |effort|
        AgentCliRuntime::Profiles.opencode_variant_arguments(effort)
      },
      routed_effort_values: AgentCliRuntime::Profiles::OPENCODE_VARIANTS,
      # Provider credentials are scrubbed from the child by the component
      # inventory, but none are forwarded unless the operator explicitly
      # names them in agents.opencode.credential_env.
      opencode_credential_environment_keys: []
    )

    register(:opencode, OPENCODE)
  end
end
