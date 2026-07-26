require "hive/agent_profile"
require "hive/skill_check"
require "hive/agent_profiles/usage_extractors"

module Hive
  module AgentProfiles
    # Claude Code profile. Reproduces today's hardcoded build_cmd in
    # lib/hive/agent.rb so existing 4-execute / brainstorm / plan / pr
    # behavior is unchanged when callers pass profile: AgentProfiles.lookup(:claude).
    #
    # Source of truth: docs/notes/headless-agent-cli-matrix.md (claude column).
    CLAUDE = AgentProfile.new(
      name: :claude,
      bin_default: "claude",
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      permission_skip_flag: "--dangerously-skip-permissions",
      add_dir_flag: "--add-dir",
      budget_flag: "--max-budget-usd",
      output_format_flags: [
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--no-session-persistence"
      ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      headless_supported: true,
      min_version: Hive::MIN_CLAUDE_VERSION,
      status_detection_mode: :state_file_marker,
      policy_capabilities: %i[tools directories commands domains settings_isolation mcp_isolation environment_isolation],
      usage_extractor: Hive::AgentProfiles::UsageExtractors::CLAUDE,
      skill_verifier: Hive::SkillCheck::Claude.method(:verify),
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:claude, **kwargs)
      },
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder: ->(effort) { [ "--effort", effort ] },
      launcher_identity: "claude-code/v1",
      tool_scope_flags: {
        allowed: "--allowedTools",
        disallowed: "--disallowedTools"
      },
      raw_cli_arguments_supported: true,
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
