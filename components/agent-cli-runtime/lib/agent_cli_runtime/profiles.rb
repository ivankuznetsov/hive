module AgentCliRuntime
  module Profiles
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
      tool_scope_flags: { allowed: "--tools" },
      output_format_flags: [ "--mode", "json", "--no-session" ],
      version_flag: "--version",
      min_version: "0.70.2",
      model_argument_builder: ->(model) { [ "--model", model ] },
      launcher_identity: "pi-coding-agent/v1",
      usage_extractor: UsageExtractors::PI,
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
      output_format_flags: [ "--output-format", "streaming-json" ],
      version_flag: "--version",
      min_version: "0.2.90",
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder:
        ->(effort) { [ "--reasoning-effort", effort ] },
      launcher_identity: "grok-cli/v1",
      usage_extractor: UsageExtractors::GROK,
      auth_configuration_probe: lambda do |home:, env:|
        if env_configured?(env, "XAI_API_KEY", "GROK_CODE_XAI_API_KEY")
          grok_auth_path(home: home, env: env) if
            env_configured?(env, "GROK_AUTH_PATH", "GROK_HOME")
          AuthConfiguration.new(status: :configured, source: "environment")
        else
          auth_from_file(
            grok_auth_path(home: home, env: env),
            source: "grok auth.json"
          )
        end
      end
    )

    PROFILES = [ CLAUDE, CODEX, PI, GROK ].to_h do |profile|
      [ profile.name, profile ]
    end.freeze
    PROVIDER_ORDER = PROFILES.keys.freeze
    private_constant :PROFILES
  end
end
