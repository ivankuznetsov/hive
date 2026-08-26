require "hive/agent_support"

module Hive::AgentSupport::Claude
  autoload :Interactive, "hive/agent_support/claude/interactive"
  autoload :Runtime, "hive/agent_support/claude/runtime"
  autoload :Skills, "hive/agent_support/claude/skills"
  autoload :SetupAdapter, "hive/agent_support/claude/setup_adapter"
  autoload :Stream, "hive/agent_support/claude/stream"

  module_function

  def credential_path(home: nil) = File.join(home || Dir.home, ".claude", ".credentials.json")
  def execution_identity(model) = [ "anthropic", model.to_s.empty? ? nil : model.to_s ]
  def legacy_control(cfg, name) = cfg.dig("claude", name.to_s)
  def legacy_wiki_plan_alias? = true
  def skill_alias_root = ".claude/commands/"
  def interactive_mode(cfg) = Hive::Config.claude_mode(cfg)
  def legacy_launch_options(cfg, model:, effort:)
    [ Hive::Config.claude_permission_mode(cfg), Hive::Config.claude_cli_flags(cfg, model:, effort:) ]
  end
  def default_model(**options)
    Hive::ImplementationIdentity::NativeDefaults.resolve(:claude, **options) do |project_root:, home:|
      defaults = Hive::ImplementationIdentity::NativeDefaults
      defaults.json_model(defaults.paths(project_root, home, ".claude/settings.json"), %w[model])
    end
  end
end
