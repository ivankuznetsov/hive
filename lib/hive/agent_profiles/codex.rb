require "hive/agent_profile"

module Hive
  module AgentProfiles
    # OpenAI Codex CLI profile. Headless invocation is the `exec` subcommand.
    # Permission skip uses --dangerously-bypass-approvals-and-sandbox to
    # match claude's full-bypass intent (ADR-008 single-developer trust
    # model). --add-dir is single-arg-per-flag (repeated), unlike claude's
    # variadic single flag.
    #
    # No native dollar budget cap; hive enforces wall-clock timeout only.
    #
    # Source of truth: docs/notes/headless-agent-cli-matrix.md (codex column).
    CODEX = AgentProfile.new(
      name: :codex,
      bin_default: "codex",
      env_bin_override_key: "HIVE_CODEX_BIN",
      # Codex headless mode is the `exec` subcommand. The first positional
      # after the bin is `exec`; subsequent flags are exec-scoped.
      headless_flag: "exec",
      permission_skip_flag: "--dangerously-bypass-approvals-and-sandbox",
      add_dir_flag: "--add-dir",
      budget_flag: nil, # codex has no native --max-budget-usd
      output_format_flags: [ "--json" ],
      version_flag: "--version",
      # Codex CE plugin registers skills at the top level (no plugin
      # namespace prefix needed in the prompt body).
      skill_syntax_format: "/%{skill}",
      headless_supported: true,
      min_version: "0.125.0",
      status_detection_mode: :output_file_exists
    )

    register(:codex, CODEX)
  end
end
