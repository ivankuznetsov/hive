require "hive/agent_profile"
require "hive/skill_check"

module Hive
  module AgentProfiles
    GROK = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:grok),
      auth_configuration_required: true,
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :output_file_exists,
      billing_semantics: :subscription_backed,
      skill_verifier: Hive::SkillCheck::Grok.method(:verify),
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:grok, **kwargs)
      },
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      },
      routed_effort_argument_builder: ->(effort) {
        %w[default inherit].include?(effort) ? [] :
          [ "--reasoning-effort", effort ]
      },
      routed_effort_values: %w[
        default inherit none minimal low medium high xhigh max
      ],
      structured_output_protocol: :grok_end
    )

    register(:grok, GROK)
  end
end
