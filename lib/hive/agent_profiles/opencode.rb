require "hive/agent_profile"
require "hive/agent_support"

module Hive
  module AgentProfiles
    OPENCODE = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:opencode),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :output_file_exists,
      permission_presets: %w[read-only scoped],
      skill_verifier: Hive::AgentSupport.skill_verifier(:opencode),
      default_model_resolver: Hive::AgentSupport.model_resolver(:opencode),
      routed_model_argument_builder: lambda { |model|
        AgentCliRuntime::Profiles.opencode_model_arguments(model)
      },
      routed_effort_argument_builder: lambda { |effort|
        AgentCliRuntime::Profiles.opencode_variant_arguments(effort)
      },
      routed_effort_values: AgentCliRuntime::Profiles::OPENCODE_VARIANTS
    )

    register(:opencode, OPENCODE)
  end
end
