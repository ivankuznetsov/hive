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
      usage_extractor: Hive::AgentProfiles::UsageExtractors::CLAUDE,
      skill_verifier: Hive::SkillCheck::Claude.method(:verify),
      model_renderer: lambda { |value|
        value == "inherit" ? [] : [ "--model", value ]
      },
      effort_renderer: lambda { |value|
        %w[default inherit].include?(value) ? [] : [ "--effort", value ]
      },
      effort_values: %w[default inherit low medium high xhigh max]
    )

    register(:claude, CLAUDE)
  end
end
