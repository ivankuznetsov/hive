require "hive/agent_profile"
require "hive/agent_support"

module Hive
  module AgentProfiles
    PI = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:pi),
      auth_configuration_required: true,
      skill_syntax_format: "/skill:%{skill}",
      status_detection_mode: :output_file_exists,
      billing_semantics: :subscription_backed,
      skill_verifier: Hive::AgentSupport.skill_verifier(:pi),
      default_model_resolver: Hive::AgentSupport.model_resolver(:pi),
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      }
    )

    register(:pi, PI)
  end
end
