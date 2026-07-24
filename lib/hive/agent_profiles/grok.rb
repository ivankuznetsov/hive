require "hive/agent_profile"
require "hive/agent_profiles/usage_extractors"

module Hive
  module AgentProfiles
    # xAI Grok CLI profile (x.ai/cli). Headless via -p / --single; the JSON
    # stream comes from --output-format streaming-json.
    #
    # ADR-008 boundary notes:
    # - --always-approve is grok's full permission bypass (its --allow/--deny
    #   rules document Claude Code equivalences, but hive's single-developer
    #   trust model wants the bypass, matching claude/codex profiles).
    # - No --add-dir equivalent; filesystem isolation is the OS user's bound
    #   only (same trade-off as pi, covered by ADR-018).
    # - No native dollar budget cap; hive enforces wall-clock timeout only.
    # - The stream carries NO token usage events (thought/text/tool events,
    #   then a terminal `end`); unavailable usage remains nil rather than
    #   being recorded as a measured zero.
    #
    # Model and reasoning effort ride the CLI defaults unless the invoker
    # pins them (-m / --reasoning-effort); grok's default model is the
    # current flagship (grok-4.5 at profile-authoring time).
    #
    # Grok accepts an interactive device login or XAI_API_KEY.
    # GROK_AUTH_PATH selects the credential file directly, while GROK_HOME
    # relocates the CLI state directory; GROK_CODE_XAI_API_KEY remains a
    # backward-compatible key for custom-model configurations.
    GROK_PREFLIGHT = -> {
      api_key = [ ENV["XAI_API_KEY"], ENV["GROK_CODE_XAI_API_KEY"] ].find do |value|
        !value.to_s.strip.empty?
      end
      explicit_path = [ ENV["GROK_AUTH_PATH"], ENV["GROK_HOME"] ].any? do |value|
        !value.to_s.strip.empty?
      end

      auth_path =
        begin
          Hive::AgentProfiles.grok_auth_path if explicit_path || !api_key
        rescue ArgumentError => e
          raise Hive::AgentError,
                "grok profile preflight failed: cannot resolve auth path (#{e.message}). " \
                "Set $HOME/GROK_AUTH_PATH/GROK_HOME, XAI_API_KEY, or run `grok login --device-auth`."
        end
      next nil if api_key

      unless File.exist?(auth_path)
        raise Hive::AgentError,
              "grok profile preflight failed: #{auth_path} not found. " \
              "Run `grok login --device-auth` or set XAI_API_KEY before using grok as a hive agent CLI."
      end

      content =
        begin
          File.read(auth_path)
        rescue SystemCallError => e
          raise Hive::AgentError,
                "grok profile preflight failed: cannot read #{auth_path} (#{e.class.name.split('::').last}: #{e.message})."
        end

      stripped = content.strip
      not_logged_in = stripped.empty? ||
                      stripped == "{}" ||
                      stripped.match?(/\A\{\s*\}\z/m)

      if not_logged_in
        raise Hive::AgentError,
              "grok profile preflight failed: no credential in #{auth_path}. " \
              "Run `grok login --device-auth` or set XAI_API_KEY."
      end

      nil
    }

    GROK = AgentProfile.new(
      name: :grok,
      bin_default: "grok",
      env_bin_override_key: "HIVE_GROK_BIN",
      headless_flag: "-p",
      prompt_style: :headless_flag_value, # -p/--single TAKES the prompt as its value
      permission_skip_flag: "--always-approve",
      add_dir_flag: nil,
      budget_flag: nil,
      output_format_flags: [ "--output-format", "streaming-json" ],
      version_flag: "--version",
      # Grok registers extension commands at the top level (`/<name>`), like
      # codex. UNVERIFIED against a skill-invoking stage — grok has no
      # skill_verifier yet, so stage prompts fall back to plain instruction
      # text when the skill is absent.
      skill_syntax_format: "/%{skill}",
      headless_supported: true,
      min_version: "0.2.90",
      status_detection_mode: :output_file_exists,
      preflight: GROK_PREFLIGHT,
      usage_extractor: Hive::AgentProfiles::UsageExtractors::GROK,
      skill_verifier: nil,
      default_model_resolver: ->(**kwargs) {
        Hive::ImplementationIdentity::NativeDefaults.resolve(:grok, **kwargs)
      },
      model_argument_builder: ->(model) { [ "--model", model ] },
      routed_model_argument_builder: ->(model) {
        %w[default inherit].include?(model) ? [] : [ "--model", model ]
      },
      launcher_identity: "grok-cli/v1"
    )

    register(:grok, GROK)
  end
end
