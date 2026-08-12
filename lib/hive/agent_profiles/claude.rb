require "hive/agent_profile"
require "hive/skill_check"

module Hive
  module AgentProfiles
    # Provider compatibility comes from agent-cli-runtime. This adapter owns
    # only Hive skills, defaults, routing policy, and stage status semantics.
    CLAUDE = AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:claude),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker,
      billing_semantics: :subscription_backed,
      policy_capabilities: %i[
        tools directories commands domains settings_isolation mcp_isolation
        environment_isolation
      ],
      skill_verifier: Hive::SkillCheck::Claude.method(:verify),
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:claude, **kwargs)
      },
      routed_model_argument_builder: ->(model) {
        model == "inherit" ? [] : [ "--model", model ]
      },
      routed_effort_argument_builder: ->(effort) {
        %w[default inherit].include?(effort) ? [] : [ "--effort", effort ]
      },
      routed_effort_values: %w[default inherit low medium high xhigh max],
      cli_capabilities: {
        safe_mode: [ "--safe-mode" ],
        patrol_review_context: [
          "--safe-mode", "--disable-slash-commands",
          "--tools", "Read,Grep,Glob,Write"
        ],
        patrol_fix_context: [
          "--safe-mode", "--disable-slash-commands",
          "--tools", "Read,Grep,Glob,Bash,Edit,Write"
        ]
      },
      initial_context_tokens: 20_000
    )

    register(:claude, CLAUDE)
  end
end
