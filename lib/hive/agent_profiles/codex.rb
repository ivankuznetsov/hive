require "hive/agent_profile"
require "hive/skill_check"

module Hive
  module AgentProfiles
    CODEX = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:codex),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :output_file_exists,
      billing_semantics: :subscription_backed,
      skill_verifier: Hive::SkillCheck::Codex.method(:verify),
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:codex, **kwargs)
      },
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      },
      routed_effort_argument_builder: ->(effort) {
        %w[default inherit].include?(effort) ? [] :
          [ "-c", "model_reasoning_effort=#{effort}" ]
      },
      routed_effort_values: %w[
        default inherit none minimal low medium high xhigh
      ],
      routing_argument_placement: :global
    )

    register(:codex, CODEX)
  end
end
