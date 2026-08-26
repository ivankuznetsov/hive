require "json"
require "rubygems/version"
require "hive/skill_check"

module Hive::AgentSupport::Codex::Skills
  extend Hive::AgentSupport::SkillPolicy

  module_function

  def resolve(invocation, project_root: nil, environment: ENV)
    parsed = Hive::SkillCheck.parse(invocation)
    home = environment["HOME"] || Dir.home
    config_dir = environment["CODEX_HOME"].to_s
    config_dir = File.join(home, ".codex") if config_dir.empty?
    config_dir = File.expand_path(config_dir)
    candidates = candidates(parsed, config_dir:, project_root:)
    path = Hive::SkillCheck.first_existing(candidates)
    return resolution(:present, candidates, path:, message: path) if path

    resolution(:missing, candidates, message: install_hint(parsed))
  rescue ArgumentError => error
    resolution(:missing, [], message: "codex: #{error.message}")
  end

  def candidates(invocation, config_dir:, project_root:)
    name = Hive::SkillCheck.glob_escape(invocation.name)
    if invocation.plugin
      plugin = Hive::SkillCheck.glob_escape(invocation.plugin)
      return Dir[File.join(
        config_dir, "plugins/cache/*", plugin, "*", "skills", name, "SKILL.md"
      )]
    end

    paths = []
    paths << File.join(project_root, ".codex/skills/#{invocation.name}/SKILL.md") if project_root
    paths << File.join(config_dir, "skills/#{invocation.name}/SKILL.md")
    paths << File.join(config_dir, "skills/.system/#{invocation.name}/SKILL.md")
    paths.concat(Dir[File.join(
      config_dir, "plugins/cache/*/*/*/skills", name, "SKILL.md"
    )])
  end

  def install_hint(invocation)
    if invocation.plugin
      "codex: /#{invocation.plugin}:#{invocation.name} not found under " \
        "~/.codex/plugins/cache/*/#{invocation.plugin}/*/skills/. " \
        "Install via `codex plugin add <plugin>@<marketplace>` for the marketplace " \
        "that ships #{invocation.plugin}."
    else
      "codex: /#{invocation.name} not found under ~/.codex/skills/, " \
        "~/.codex/skills/.system/, or any installed plugin's skills/<name>/SKILL.md. " \
        "Codex has no user-level slash-command directory; either install a skill named " \
        "#{invocation.name.inspect}, install a plugin that ships it, or override the " \
        "stage's skill in config.yml (e.g. `plan.skill: /ce-plan`)."
    end
  end

  def live_inventory(bin:, native_spec:, issues:, run:, failure:, **)
    plugins_result = run.call([ bin, "plugin", "list", "--available", "--json" ])
    marketplaces_result = run.call([ bin, "plugin", "marketplace", "list", "--json" ])
    issues << [ "incompatible", "codex plugin inventory failed: #{failure.call(plugins_result)}" ] unless plugins_result.success?
    unless marketplaces_result.success?
      issues << [
        "incompatible",
        "codex marketplace inventory failed: #{failure.call(marketplaces_result)}"
      ]
    end
    plugins = JSON.parse(plugins_result.stdout).fetch("installed")
    marketplaces = JSON.parse(marketplaces_result.stdout).fetch("marketplaces")
    raise TypeError, "installed plugin list must be an Array" unless plugins.is_a?(Array)
    raise TypeError, "marketplace list must be an Array" unless marketplaces.is_a?(Array)

    plugin = plugins.find { |entry| entry["pluginId"] == native_spec.package }
    marketplace = marketplaces.find { |entry| entry["name"] == native_spec.marketplace }
    {
      "package" => plugin && {
        "id" => plugin["pluginId"], "version" => plugin["version"],
        "enabled" => plugin.fetch("enabled", true), "install_path" => nil,
        "source" => plugin.dig("source", "url") || plugin.dig("marketplaceSource", "source")
      }.freeze,
      "marketplace" => marketplace && {
        "name" => marketplace["name"],
        "source" => marketplace.dig("marketplaceSource", "source")
      }.freeze
    }
  end

  def filesystem_inventory(native_spec:, root:, package_version:, **)
    config_path = File.join(root, "config.toml")
    marketplace_names = [
      "marketplaces.#{native_spec.marketplace}",
      "marketplaces.\"#{native_spec.marketplace}\""
    ]
    plugin_name = "plugins.\"#{native_spec.package}\""
    sections = toml_sections(
      read_optional(config_path), selected: marketplace_names + [ plugin_name ]
    )
    marketplace = marketplace_names.filter_map { |name| sections[name] }.first
    plugin = sections[plugin_name]
    install_path = install_path(root, native_spec, package_version)
    {
      "package" => plugin && install_path && {
        "id" => native_spec.package,
        "version" => package_version.call(install_path),
        "enabled" => plugin.fetch("enabled", true),
        "install_path" => install_path,
        "source" => marketplace && marketplace["source"]
      }.freeze,
      "marketplace" => marketplace && {
        "name" => native_spec.marketplace, "source" => marketplace["source"]
      }.freeze
    }.freeze
  end

  def install_path(root, native_spec, package_version)
    plugin = native_spec.package.split("@", 2).first
    base = File.join(root, "plugins", "cache", native_spec.marketplace, plugin)
    return base if package_version.call(base)
    return unless File.directory?(base)

    Dir.children(base).sort.filter_map do |entry|
      path = File.join(base, entry)
      next unless File.directory?(path)

      version = package_version.call(path) || entry
      [ Gem::Version.new(version), path ]
    rescue ArgumentError
      nil
    end.max_by { |version, path| [ version, path ] }&.last
  end

  def toml_sections(content, selected:)
    sections = {}
    current = nil
    content.each_line.with_index(1) do |line, line_number|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")
      if (match = stripped.match(/\A\[([^\]]+)\]\z/))
        current = selected.include?(match[1]) ? match[1] : nil
        sections[current] ||= {} if current
        next
      end
      next unless current

      match = stripped.match(/\A([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*\z/)
      sections.fetch(current)[match[1]] = toml_scalar(match[2], line_number) if match
    end
    sections.freeze
  end

  def toml_scalar(value, line_number)
    return true if value == "true"
    return false if value == "false"
    return value[1...-1] if value.start_with?("\"") && value.end_with?("\"")

    raise TypeError, "unsupported config.toml value at line #{line_number}"
  end

  def read_optional(path)
    File.binread(path)
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
    ""
  end

  private_class_method :candidates, :install_hint, :install_path, :toml_sections,
    :toml_scalar, :read_optional
end
