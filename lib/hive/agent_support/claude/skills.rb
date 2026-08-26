require "json"
require "hive/skill_check"

module Hive::AgentSupport::Claude::Skills
  extend Hive::AgentSupport::SkillPolicy

  module_function

  def resolve(invocation, project_root: nil, environment: ENV)
    parsed = Hive::SkillCheck.parse(invocation)
    home = environment["HOME"] || Dir.home
    config_dir = environment["CLAUDE_CONFIG_DIR"].to_s
    config_dir = File.join(home, ".claude") if config_dir.empty?
    candidates = candidates(parsed, config_dir: File.expand_path(config_dir), project_root:)
    path = Hive::SkillCheck.first_existing(candidates)
    return resolution(:present, candidates, path:, message: path) if path

    resolution(:missing, candidates, message: install_hint(parsed))
  rescue ArgumentError => error
    resolution(:missing, [], message: "claude: #{error.message}")
  end

  def candidates(invocation, config_dir:, project_root:)
    name = Hive::SkillCheck.glob_escape(invocation.name)
    if invocation.plugin
      plugin = Hive::SkillCheck.glob_escape(invocation.plugin)
      return [
        "plugins/cache/*/#{plugin}/*/skills/#{name}/SKILL.md",
        "plugins/cache/*/#{plugin}/*/commands/#{name}.md",
        "plugins/marketplaces/*/plugins/#{plugin}/skills/#{name}/SKILL.md",
        "plugins/marketplaces/*/plugins/#{plugin}/commands/#{name}.md"
      ].flat_map { |pattern| Dir[File.join(config_dir, pattern)] }
    end

    paths = []
    if project_root
      paths << File.join(project_root, ".claude/commands/#{invocation.name}.md")
      paths << File.join(project_root, ".claude/skills/#{invocation.name}/SKILL.md")
    end
    paths << File.join(config_dir, "commands/#{invocation.name}.md")
    paths << File.join(config_dir, "skills/#{invocation.name}/SKILL.md")
    [
      "plugins/cache/*/*/*/skills/#{name}/SKILL.md",
      "plugins/cache/*/*/*/commands/#{name}.md",
      "plugins/marketplaces/*/plugins/*/skills/#{name}/SKILL.md",
      "plugins/marketplaces/*/plugins/*/commands/#{name}.md"
    ].each { |pattern| paths.concat(Dir[File.join(config_dir, pattern)]) }
    paths
  end

  def live_inventory(bin:, native_spec:, issues:, run:, failure:, **)
    plugins_result = run.call([ bin, "plugin", "list", "--json" ])
    marketplaces_result = run.call([ bin, "plugin", "marketplace", "list", "--json" ])
    unless plugins_result.success?
      issues << [ "incompatible", "claude plugin inventory failed: #{failure.call(plugins_result)}" ]
    end
    unless marketplaces_result.success?
      issues << [ "incompatible", "claude marketplace inventory failed: #{failure.call(marketplaces_result)}" ]
    end
    plugins = JSON.parse(plugins_result.stdout)
    marketplaces = JSON.parse(marketplaces_result.stdout)
    raise TypeError, "plugin list must be an Array" unless plugins.is_a?(Array)
    raise TypeError, "marketplace list must be an Array" unless marketplaces.is_a?(Array)

    plugin = plugins.find { |entry| entry["id"] == native_spec.package }
    marketplace = marketplaces.find { |entry| entry["name"] == native_spec.marketplace }
    {
      "package" => plugin && {
        "id" => plugin["id"], "version" => plugin["version"],
        "enabled" => plugin.fetch("enabled", true),
        "install_path" => plugin["installPath"], "source" => nil
      }.freeze,
      "marketplace" => marketplace && {
        "name" => marketplace["name"],
        "source" => marketplace["repo"] || marketplace["source"]
      }.freeze
    }
  end

  def filesystem_inventory(native_spec:, root:, read_json:, **)
    plugins_path = File.join(root, "plugins", "installed_plugins.json")
    marketplaces_path = File.join(root, "plugins", "known_marketplaces.json")
    settings_path = File.join(root, "settings.json")
    plugins = read_json.call(plugins_path, { "plugins" => {} }).fetch("plugins")
    marketplaces = read_json.call(marketplaces_path, {})
    settings = read_json.call(settings_path, {})
    raise TypeError, "#{plugins_path} plugins must be an object" unless plugins.is_a?(Hash)
    raise TypeError, "#{marketplaces_path} must be an object" unless marketplaces.is_a?(Hash)
    raise TypeError, "#{settings_path} must be an object" unless settings.is_a?(Hash)

    entries = plugins.fetch(native_spec.package, [])
    unless entries.is_a?(Array)
      raise TypeError, "#{plugins_path} entry #{native_spec.package.inspect} must be an array"
    end
    entry = entries.find { |candidate| candidate.is_a?(Hash) && candidate["scope"] == native_spec.scope } ||
      entries.find { |candidate| candidate.is_a?(Hash) }
    marketplace = marketplaces[native_spec.marketplace]
    if marketplace && !marketplace.is_a?(Hash)
      raise TypeError, "#{marketplaces_path} entry #{native_spec.marketplace.inspect} must be an object"
    end
    enabled_plugins = settings.fetch("enabledPlugins", {})
    unless enabled_plugins.nil? || enabled_plugins.is_a?(Hash)
      raise TypeError, "#{settings_path} enabledPlugins must be an object"
    end
    enabled = enabled_plugins.nil? ? true : enabled_plugins.fetch(native_spec.package, true)
    unless [ true, false ].include?(enabled)
      raise TypeError, "#{settings_path} enabledPlugins entry #{native_spec.package.inspect} must be boolean"
    end

    {
      "package" => entry && {
        "id" => native_spec.package, "version" => entry["version"],
        "enabled" => enabled, "install_path" => entry["installPath"], "source" => nil
      }.freeze,
      "marketplace" => marketplace && {
        "name" => native_spec.marketplace, "source" => marketplace_source(marketplace)
      }.freeze
    }.freeze
  end

  def marketplace_source(entry)
    source = entry["source"]
    return source["repo"] || source["url"] || source["source"] if source.is_a?(Hash)

    entry["repo"] || source
  end

  def install_hint(invocation)
    if invocation.plugin
      "claude: /#{invocation.plugin}:#{invocation.name} not found under " \
        "~/.claude/plugins/cache/*/#{invocation.plugin}/*/skills/ or " \
        "~/.claude/plugins/marketplaces/*/plugins/#{invocation.plugin}/skills/. " \
        "Install via `claude plugin install <marketplace>` for the marketplace " \
        "that ships #{invocation.plugin}."
    else
      "claude: /#{invocation.name} not found under ~/.claude/{commands,skills}/, any " \
        "installed plugin's skills/<name>/ or commands/<name>.md, or " \
        "<project>/.claude/.... Install as a user-level slash command " \
        "(write ~/.claude/commands/#{invocation.name}.md), as a user skill " \
        "(write ~/.claude/skills/#{invocation.name}/SKILL.md), or via " \
        "`claude plugin install <marketplace>` for a plugin that ships #{invocation.name}."
    end
  end

  private_class_method :candidates, :marketplace_source, :install_hint
end
