require "hive/agent_profile"

module Hive
  module AgentProfiles
    MUSE = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:muse),
      auth_configuration_required: true,
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :output_file_exists,
      billing_semantics: :subscription_backed,
      skill_verifier: Hive::AgentSupport.skill_verifier(:muse),
      default_model_resolver: Hive::AgentSupport.model_resolver(:muse),
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      },
      routed_effort_argument_builder: ->(effort) {
        %w[default inherit].include?(effort) ? [] :
          [ "--reasoning-effort", effort ]
      },
      routed_effort_values: %w[
        default inherit none minimal low medium high xhigh max ultra
      ],
      structured_output_protocol: :muse_terminal
    )

    register(:muse, MUSE)
  end
end
