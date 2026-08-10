require "hive/agent_profile"
require "hive/skill_check"
require "hive/agent_profiles/usage_extractors"

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
      prompt_style: :stdin,
      permission_skip_flag: "--dangerously-bypass-approvals-and-sandbox",
      workspace_write_flags: [
        "--sandbox", "workspace-write",
        "-c", 'approval_policy="never"',
        "--ephemeral", "--ignore-user-config", "--ignore-rules"
      ],
      read_only_flags: [
        "--sandbox", "read-only",
        "-c", 'approval_policy="never"',
        "--ephemeral", "--ignore-user-config", "--ignore-rules"
      ],
      add_dir_flag: "--add-dir",
      budget_flag: nil, # codex has no native --max-budget-usd
      output_format_flags: [ "--json" ],
      version_flag: "--version",
      # Codex CE plugin registers skills at the top level (no plugin
      # namespace prefix needed in the prompt body).
      skill_syntax_format: "/%{skill}",
      headless_supported: true,
      min_version: "0.125.0",
      status_detection_mode: :output_file_exists,
      usage_extractor: Hive::AgentProfiles::UsageExtractors::CODEX,
      skill_verifier: Hive::SkillCheck::Codex.method(:verify),
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:codex, **kwargs)
      },
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder: ->(effort) { [ "-c", "model_reasoning_effort=#{effort}" ] },
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      },
      routed_effort_argument_builder: ->(effort) {
        %w[default inherit].include?(effort) ? [] : [ "-c", "model_reasoning_effort=#{effort}" ]
      },
      routed_effort_values: %w[default inherit none minimal low medium high xhigh],
      routing_argument_placement: :global,
      launcher_identity: "codex-cli/v1"
    )

    register(:codex, CODEX)
  end
end
