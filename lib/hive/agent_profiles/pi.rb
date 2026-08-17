require "hive/agent_profile"
require "hive/skill_check"

module Hive
  module AgentProfiles
    PI = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:pi),
      auth_configuration_required: true,
      skill_syntax_format: "/skill:%{skill}",
      status_detection_mode: :output_file_exists,
      billing_semantics: :subscription_backed,
      structured_output_protocol: :pi_agent_end,
      skill_verifier: Hive::SkillCheck::Pi.method(:verify),
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:pi, **kwargs)
      },
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      }
    )

    register(:pi, PI)
  end
end
