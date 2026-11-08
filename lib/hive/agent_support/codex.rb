require "hive/agent_support"

module Hive::AgentSupport::Codex
  LEGACY_CLAUDE_MODEL = /\A(?:claude-|anthropic\/claude-)/i.freeze

  autoload :ArtifactPolicy, "hive/agent_support/codex/artifact_policy"
  autoload :Mcp, "hive/agent_support/codex/mcp"
  autoload :Reviewer, "hive/agent_support/codex/reviewer"
  autoload :Runtime, "hive/agent_support/codex/runtime"
  autoload :Skills, "hive/agent_support/codex/skills"
  autoload :SetupAdapter, "hive/agent_support/codex/setup_adapter"
  autoload :UserConfig, "hive/agent_support/codex/user_config"

  module_function

  def credential_path(home: nil) = File.join(home || Dir.home, ".codex", "auth.json")
  def execution_identity(model) = [ "openai", model.to_s.empty? ? nil : model.to_s ]
  # Codex's `--json` stream never names the model that served a turn, so a
  # Codex reviewer cannot prove its family from a served-model field. Hive
  # launches Codex with `--ignore-user-config` and replays only
  # `model_provider` / `profile` from the operator's config (see Mcp), so when
  # neither selects a non-OpenAI provider the launch itself guarantees the
  # built-in OpenAI provider, and the OpenAI family is attested. Any other
  # provider, or an unreadable config, stays unattested (fail closed).
  def attests_family_without_served_model?(family:, environment: ENV)
    return false unless family.to_s.strip.downcase == "openai"

    config = UserConfig.load(UserConfig.path(env: environment))
    providers = [ config["model_provider"] ]
    profile = UserConfig.string(config["profile"])
    providers << config.table("profiles", profile)["model_provider"] if profile
    providers.compact.all? { |raw| UserConfig.string(raw) == "openai" }
  rescue StandardError
    false
  end
  def recoverable_planner_identity?(identity)
    identity["model"].to_s.match?(LEGACY_CLAUDE_MODEL)
  end
  def projection_sources = [ "agents/openai.yaml" ]
  def skill_invocation?(invocation) = invocation.match?(/\A\$[A-Za-z0-9_.-]+\z/)

  def effort_from_argv(argv)
    argv.each_cons(2).filter_map do |flag, value|
      value[/\Amodel_reasoning_effort=([a-z][a-z0-9_-]*)\z/, 1] if flag == "-c"
    end.first
  end

  def default_model(**options)
    Hive::ImplementationIdentity::NativeDefaults.resolve(:codex, **options) do |project_root:, home:|
      defaults = Hive::ImplementationIdentity::NativeDefaults
      defaults.toml_model(defaults.paths(project_root, home, ".codex/config.toml"))
    end
  end

  def prepare_capture(**options) = ArtifactPolicy.prepare(**options)

  def validate_capture_profile!(profile:, unsupported:)
    return if profile.workspace_write_supported? && profile.add_dir_flag

    raise Hive::ConfigError,
          "artifacts evidence producer #{profile.name.inspect} cannot safely produce " \
          "#{unsupported.join(', ')} proof; configure a workspace-sandboxed producer " \
          "with per-attempt writable roots"
  end
end
