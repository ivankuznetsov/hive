require "hive/agent_profile"

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
      status_detection_mode: :state_file_marker
    )

    register(:claude, CLAUDE)
  end
end
