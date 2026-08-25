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
      skill_verifier: ->(invocation, project_root: nil) {
        Hive::AgentSupport.for(PI)::Skills.verify(invocation, project_root: project_root)
      },
      default_model_resolver: ->(**kwargs) {
        Hive::AgentSupport.for(PI).default_model(**kwargs)
      },
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      }
    )

    register(:pi, PI)
  end
end
