require "hive/agent_profile"

module Hive
  module AgentProfiles
    AGY = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:agy),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :output_file_exists,
      billing_semantics: :subscription_backed,
      skill_verifier: Hive::AgentSupport.skill_verifier(:agy),
      default_model_resolver: Hive::AgentSupport.model_resolver(:agy),
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      },
      routed_effort_argument_builder: ->(effort) {
        %w[default inherit].include?(effort) ? [] : [ "--effort", effort ]
      },
      routed_effort_values: %w[default inherit low medium high xhigh max],
      structured_output_protocol: :agy_result
    )

    register(:agy, AGY)
  end
end
