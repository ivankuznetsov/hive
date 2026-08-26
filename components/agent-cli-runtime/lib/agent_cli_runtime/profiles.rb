module AgentCliRuntime
  module Profiles
    PI_CREDENTIAL_ENVIRONMENT_KEYS = %w[
      AI_GATEWAY_API_KEY
      ANTHROPIC_API_KEY
      ANTHROPIC_AUTH_TOKEN
      ANTHROPIC_OAUTH_TOKEN
      ANT_LING_API_KEY
      AWS_ACCESS_KEY_ID
      AWS_BEARER_TOKEN_BEDROCK
      AWS_CONTAINER_CREDENTIALS_FULL_URI
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
      AWS_PROFILE
      AWS_SECRET_ACCESS_KEY
      AWS_SESSION_TOKEN
      AWS_WEB_IDENTITY_TOKEN_FILE
      AZURE_OPENAI_API_KEY
      BASETEN_API_KEY
      CEREBRAS_API_KEY
      CLOUDFLARE_API_KEY
      COPILOT_GITHUB_TOKEN
      DEEPSEEK_API_KEY
      FIREWORKS_API_KEY
      GEMINI_API_KEY
      GOOGLE_APPLICATION_CREDENTIALS
      GOOGLE_CLOUD_API_KEY
      GROQ_API_KEY
      HF_TOKEN
      KIMI_API_KEY
      MINIMAX_API_KEY
      MINIMAX_CN_API_KEY
      MISTRAL_API_KEY
      MOONSHOT_API_KEY
      NVIDIA_API_KEY
      OPENCODE_API_KEY
      OPENAI_API_KEY
      OPENROUTER_API_KEY
      QWEN_TOKEN_PLAN_API_KEY
      RADIUS_API_KEY
      TOGETHER_API_KEY
      XAI_API_KEY
      XIAOMI_API_KEY
      XIAOMI_TOKEN_PLAN_AMS_API_KEY
      XIAOMI_TOKEN_PLAN_CN_API_KEY
      XIAOMI_TOKEN_PLAN_SGP_API_KEY
      ZAI_API_KEY
      ZAI_CODING_CN_API_KEY
    ].freeze

    module_function

    def names
      PROVIDER_ORDER
    end

    def fetch(name)
      PROFILES.fetch(name.to_sym) do
        raise UnknownProvider,
              "unknown provider #{name.inspect}; expected one of #{PROVIDER_ORDER.join(', ')}"
      end
    end

    def resolve(profile)
      profile.is_a?(Profile) ? profile : fetch(profile)
    end

    def auth_from_file(path, source:)
      configured = File.file?(path) &&
                   !File.read(path).strip.match?(/\A(?:|\{\s*\})\z/m)
      AuthConfiguration.new(
        status: configured ? :configured : :missing,
        source: source
      )
    rescue SystemCallError, ArgumentError => e
      AuthConfiguration.new(
        status: :missing,
        source: source,
        diagnostic: Redactor.diagnostic(e)
      )
    end

    def home_path(home, *parts)
      File.join(home || Dir.home, *parts)
    end

    def env_configured?(env, *keys)
      keys.any? { |key| !env[key].to_s.strip.empty? }
    end

    def grok_auth_path(home:, env:)
      auth_path = env["GROK_AUTH_PATH"]
      grok_home = env["GROK_HOME"]
      if !auth_path.to_s.empty?
        raise ArgumentError, "GROK_AUTH_PATH must be absolute" unless File.absolute_path?(auth_path)

        return auth_path
      end
      if !grok_home.to_s.empty?
        raise ArgumentError, "GROK_HOME must be absolute" unless File.absolute_path?(grok_home)

        return File.join(grok_home, "auth.json")
      end
      home_path(home, ".grok", "auth.json")
    end

    def opencode_auth_path(home:, env:)
      data_home = env["XDG_DATA_HOME"]
      if !data_home.to_s.empty?
        unless File.absolute_path?(data_home)
          raise ArgumentError, "XDG_DATA_HOME must be absolute"
        end

        return File.join(data_home, "opencode", "auth.json")
      end

      home_path(home, ".local", "share", "opencode", "auth.json")
    end

    def opencode_model_arguments(model)
      route = Route.parse(model)
      [ "--model", route.to_s ]
    end

    OPENCODE_VARIANTS = %w[minimal low medium high xhigh max].freeze

    def opencode_variant_arguments(variant)
      normalized = variant.to_s
      unless OPENCODE_VARIANTS.include?(normalized)
        raise ArgumentError,
              "unsupported OpenCode variant #{variant.inspect}; expected one of " \
              "#{OPENCODE_VARIANTS.join(', ')}"
      end

      [ "--variant", normalized ]
    end

    CLAUDE = Profile.new(
      name: :claude,
      bin_default: "claude",
      env_bin_override_keys: %w[AGENT_CLI_RUNTIME_CLAUDE_BIN HIVE_CLAUDE_BIN],
      headless_flag: "-p",
      permission_skip_flag: "--dangerously-skip-permissions",
      add_dir_flag: "--add-dir",
      tool_scope_flags: {
        allowed: "--allowedTools",
        disallowed: "--disallowedTools"
      },
      budget_flag: "--max-budget-usd",
      output_format_flags: [
        "--output-format", "stream-json",
        "--include-partial-messages", "--verbose", "--no-session-persistence"
      ],
      version_flag: "--version",
      min_version: "2.1.118",
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder: ->(effort) { [ "--effort", effort ] },
      launcher_identity: "claude-code/v1",
      usage_extractor: UsageExtractors::CLAUDE,
      credential_environment_keys: %w[
        ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_API_KEY
      ],
      configuration_environment_key: "CLAUDE_CONFIG_DIR",
      default_configuration_directory: ".claude",
      raw_cli_arguments_supported: true,
      auth_configuration_probe: lambda do |home:, env:|
        if env_configured?(env, "ANTHROPIC_API_KEY")
          AuthConfiguration.new(status: :configured, source: "environment")
        else
          auth_from_file(
            home_path(home, ".claude", ".credentials.json"),
            source: "~/.claude/.credentials.json"
          )
        end
      end
    )

    CODEX = Profile.new(
      name: :codex,
      bin_default: "codex",
      env_bin_override_keys: %w[AGENT_CLI_RUNTIME_CODEX_BIN HIVE_CODEX_BIN],
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
      output_format_flags: [ "--json" ],
      version_flag: "--version",
      min_version: "0.125.0",
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder:
        ->(effort) { [ "-c", "model_reasoning_effort=#{effort}" ] },
      launcher_identity: "codex-cli/v1",
      usage_extractor: UsageExtractors::CODEX,
      credential_environment_keys: %w[OPENAI_API_KEY],
      configuration_environment_key: "CODEX_HOME",
      default_configuration_directory: ".codex",
      auth_configuration_probe: lambda do |home:, env:|
        if env_configured?(env, "OPENAI_API_KEY")
          AuthConfiguration.new(status: :configured, source: "environment")
        else
          auth_from_file(
            home_path(home, ".codex", "auth.json"),
            source: "~/.codex/auth.json"
          )
        end
      end
    )

    PI = Profile.new(
      name: :pi,
      bin_default: "pi",
      env_bin_override_keys: %w[AGENT_CLI_RUNTIME_PI_BIN HIVE_PI_BIN],
      headless_flag: "-p",
      # Pi reads a non-TTY stdin stream into its initial message without an
      # argv placeholder. Keeping the prompt out of argv also avoids Linux's
      # per-argument size limit on real implementation plans.
      prompt_style: :piped_stdin,
      output_format_flags: [ "--mode", "json", "--no-session" ],
      version_flag: "--version",
      min_version: "0.70.2",
      model_argument_builder: ->(model) { [ "--model", model ] },
      launcher_identity: "pi-coding-agent/v1",
      usage_extractor: UsageExtractors::PI,
      error_extractor: ErrorExtractors::PI,
      credential_environment_keys: PI_CREDENTIAL_ENVIRONMENT_KEYS,
      configuration_environment_key: "PI_CODING_AGENT_DIR",
      default_configuration_directory: ".pi/agent",
      auth_configuration_probe: lambda do |home:, env:|
        directory = env["PI_CODING_AGENT_DIR"]
        path =
          if directory.to_s.empty?
            home_path(home, ".pi", "agent", "auth.json")
          else
            raise ArgumentError, "PI_CODING_AGENT_DIR must be absolute" unless File.absolute_path?(directory)

            File.join(directory, "auth.json")
          end
        auth_from_file(path, source: "pi auth.json")
      end
    )

    GROK = Profile.new(
      name: :grok,
      bin_default: "grok",
      env_bin_override_keys: %w[AGENT_CLI_RUNTIME_GROK_BIN HIVE_GROK_BIN],
      headless_flag: "-p",
      prompt_style: :headless_flag_value,
      permission_skip_flag: "--always-approve",
      # Grok confines the filesystem natively, the same shape codex uses.
      # `workspace` limits writes to the working directory, `read-only`
      # forbids them entirely; both are built-in profiles (custom ones extend
      # them from ~/.grok/sandbox.toml). `--always-approve` suppresses the
      # interactive approval prompt, which a headless reviewer can never answer
      # — the sandbox, not the prompt, is what actually bounds the agent.
      workspace_write_flags: [ "--sandbox", "workspace", "--always-approve" ],
      read_only_flags: [ "--sandbox", "read-only", "--always-approve" ],
      output_format_flags: [ "--output-format", "streaming-json" ],
      version_flag: "--version",
      min_version: "0.2.90",
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder:
        ->(effort) { [ "--reasoning-effort", effort ] },
      launcher_identity: "grok-cli/v1",
      usage_extractor: UsageExtractors::GROK,
      credential_environment_keys: %w[GROK_AUTH_PATH XAI_API_KEY GROK_CODE_XAI_API_KEY],
      configuration_environment_key: "GROK_HOME",
      default_configuration_directory: ".grok",
      auth_configuration_probe: lambda do |home:, env:|
        if env_configured?(env, "XAI_API_KEY", "GROK_CODE_XAI_API_KEY")
          AuthConfiguration.new(status: :configured, source: "environment")
        else
          auth_from_file(
            grok_auth_path(home: home, env: env),
            source: "grok auth.json"
          )
        end
      end
    )

    OPENCODE = Profile.new(
      name: :opencode,
      bin_default: "opencode",
      env_bin_override_keys: %w[
        AGENT_CLI_RUNTIME_OPENCODE_BIN HIVE_OPENCODE_BIN
      ],
      headless_flag: "run",
      output_format_flags: [ "--format", "json" ],
      version_flag: "--version",
      # `opencode run` reads a non-TTY stdin stream as the initial message.
      # Keep implementation-sized prompts out of one argv element: Linux
      # rejects a single argument around 128 KiB with E2BIG even when the
      # complete argv remains far below ARG_MAX.
      prompt_style: :piped_stdin,
      # Bun-backed OpenCode startup can exceed the generic 10-second bound
      # under sustained host I/O even though the executable is healthy.
      version_check_timeout_sec: 30,
      min_version: "1.18.16",
      model_argument_builder: ->(model) { opencode_model_arguments(model) },
      effort_argument_builder:
        ->(variant) { opencode_variant_arguments(variant) },
      launcher_identity: "opencode-cli/v1",
      credential_environment_keys: PI_CREDENTIAL_ENVIRONMENT_KEYS,
      configuration_environment_key: "OPENCODE_CONFIG_DIR",
      default_configuration_directory: ".config/opencode",
      permission_policy_required: true,
      error_extractor: ErrorExtractors::OPENCODE,
      result_parser: OpenCode::ResultParser,
      cli_capabilities: {
        json_events: [ "run", "--format" ],
        working_directory: [ "run", "--dir" ],
        model_variant: [ "run", "--variant" ],
        pure: [ "run", "--pure" ],
        sanitized_export: [ "export", "--sanitize" ]
      },
      auth_configuration_probe: lambda do |home:, env:|
        if env_configured?(env, *PI_CREDENTIAL_ENVIRONMENT_KEYS)
          AuthConfiguration.new(status: :configured, source: "environment")
        else
          auth_from_file(
            opencode_auth_path(home:, env:),
            source: "opencode auth.json"
          )
        end
      end
    )

    PROFILES = [ CLAUDE, CODEX, PI, GROK, OPENCODE ].to_h do |profile|
      [ profile.name, profile ]
    end.freeze
    PROVIDER_ORDER = PROFILES.keys.freeze
    private_constant :PROFILES
  end
end
