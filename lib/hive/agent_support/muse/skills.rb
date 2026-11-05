require "json"
require "hive/skill_check"

module Hive::AgentSupport::Muse::Skills
  extend Hive::AgentSupport::SkillPolicy

  module_function

  # Muse discovers skills by flat id across the workspace `.agents/skills`
  # tree, its managed personal root under the XDG config directory, the
  # cross-agent `~/.agents/skills` root, the foreign Claude/Codex personal
  # roots, and installed plugin packages under the XDG data directory.
  # Skill ids are flat, so a plugin-qualified invocation resolves by its
  # skill name (scoped to that plugin's package when one is named).
  def resolve(invocation, project_root: nil, environment: ENV)
    parsed = Hive::SkillCheck.parse(invocation)
    home = environment["HOME"] || Dir.home
    config_dir = Hive::AgentSupport::Muse.config_directory(environment: environment)
    parse_errors = []
    candidates = candidates(
      parsed, config_dir: config_dir, home: home,
      project_root: project_root, environment: environment,
      parse_errors: parse_errors
    )
    path = Hive::SkillCheck.first_existing(candidates)
    return resolution(:present, candidates, parse_errors, path:, message: path) if path

    resolution(:missing, candidates, parse_errors, message: install_hint(parsed))
  rescue ArgumentError => error
    resolution(:missing, [], message: "muse: #{error.message}")
  end

  def candidates(invocation, config_dir:, home:, project_root:, environment:, parse_errors: [])
    paths = []
    if project_root
      paths << File.join(project_root, ".agents", "skills", invocation.name, "SKILL.md")
    end
    paths << File.join(config_dir, "skills", invocation.name, "SKILL.md")
    paths << File.join(home, ".agents", "skills", invocation.name, "SKILL.md")
    paths << File.join(home, ".claude", "skills", invocation.name, "SKILL.md")
    paths << File.join(home, ".codex", "skills", invocation.name, "SKILL.md")
    paths.concat(plugin_candidates(invocation, environment:, parse_errors:))
    paths
  end

  def plugin_candidates(invocation, environment:, parse_errors: [])
    data_dir = Hive::AgentSupport::Muse.data_directory(environment: environment)
    cache_root = File.join(data_dir, "plugins", "cache")
    plugin_records(environment: environment, parse_errors: parse_errors)
      .filter_map do |id, record|
        next unless record.is_a?(Hash) && record["enabled"] != false
        next if invocation.plugin && invocation.plugin != id

        package = installed_cache_path(record, data_dir: data_dir)
        next unless package

        candidate = File.join(package, "skills", invocation.name, "SKILL.md")
        jailed(candidate, cache_root, parse_errors: parse_errors)
      end
  end

  def installed_cache_path(record, data_dir:)
    cache_path = record["cache_path"].to_s
    return nil if cache_path.empty?

    File.absolute_path?(cache_path) ? cache_path : File.join(data_dir, cache_path)
  end

  def plugin_records(environment:, parse_errors: [])
    data_dir = Hive::AgentSupport::Muse.data_directory(environment: environment)
    path = File.join(data_dir, "plugins", "installed.json")
    plugins = JSON.parse(File.binread(path))["plugins"]
    raise TypeError, "#{path} plugins must be an object" unless plugins.is_a?(Hash)

    plugins
  rescue Errno::ENOENT, Errno::ENOTDIR
    {}
  rescue JSON::ParserError, TypeError, KeyError, SystemCallError => error
    parse_errors << error.message
    {}
  end

  def installed_plugin(package_id, environment: ENV)
    plugin_records(environment: environment)[package_id.to_s]
  end

  def jailed(path, root, parse_errors: [])
    candidate = canonical_path(path)
    base = canonical_path(root)
    return candidate if candidate == base ||
                          candidate.start_with?(base + File::SEPARATOR)

    parse_errors << "muse plugin path #{candidate.inspect} escapes #{base}"
    nil
  end

  def canonical_path(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path)
  end

  def repository_source(cache_path)
    return nil if cache_path.to_s.empty?

    manifest = [ ".claude-plugin/plugin.json", "plugin.json" ]
      .map { |relative| File.join(cache_path, relative) }
      .find { |path| File.file?(path) }
    return nil unless manifest

    repository = JSON.parse(File.binread(manifest))["repository"]
    repository = repository["url"] if repository.is_a?(Hash)
    repository if repository.is_a?(String) && !repository.empty?
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def live_inventory(bin:, native_spec:, issues:, run:, failure:, **)
    plugins_result = run.call([ bin, "plugins", "list", "--json" ])
    unless plugins_result.success?
      issues << [ "incompatible", "muse plugin inventory failed: #{failure.call(plugins_result)}" ]
    end
    document = JSON.parse(plugins_result.stdout)
    entries = document["plugins"] if document.is_a?(Hash)
    raise TypeError, "muse plugin list must be an Array" unless entries.is_a?(Array)
    unless entries.all?(Hash)
      raise TypeError, "muse plugin list entries must be objects"
    end

    entry = entries.find { |candidate| candidate.dig("plugin", "id") == native_spec.package }
    record = entry && entry["record"].is_a?(Hash) ? entry["record"] : {}
    {
      "package" => entry && {
        "id" => native_spec.package,
        "version" => record["version"] || entry.dig("plugin", "version"),
        "enabled" => record["enabled"] != false,
        "install_path" => record["cache_path"],
        "source" => repository_source(record["cache_path"])
      }.freeze,
      "marketplace" => nil
    }
  end

  def filesystem_inventory(native_spec:, root: nil, read_json:, environment: ENV, **)
    data_dir = Hive::AgentSupport::Muse.data_directory(environment: environment)
    registry_path = File.join(data_dir, "plugins", "installed.json")
    registry = read_json.call(registry_path, { "plugins" => {} })
    plugins = registry["plugins"] if registry.is_a?(Hash)
    raise TypeError, "#{registry_path} plugins must be an object" unless plugins.is_a?(Hash)

    record = plugins[native_spec.package]
    return { "package" => nil, "marketplace" => nil }.freeze unless record.is_a?(Hash)

    install_path = installed_cache_path(record, data_dir: data_dir)
    manifest = read_json.call(
      File.join(install_path.to_s, ".claude-plugin", "plugin.json"), {}
    )
    repository = manifest["repository"] if manifest.is_a?(Hash)
    repository = repository["url"] if repository.is_a?(Hash)
    {
      "package" => {
        "id" => native_spec.package,
        "version" => record["version"],
        "enabled" => record["enabled"] != false,
        "install_path" => install_path,
        "source" => repository.is_a?(String) && !repository.empty? ? repository : nil
      }.freeze,
      "marketplace" => nil
    }.freeze
  end

  def install_hint(invocation)
    "muse: /#{invocation.name} is not available from a Muse skill root. " \
      "Provision managed skills with `hive setup-agents --agent muse`, " \
      "install one with `muse skills install <skill-directory>`, or place " \
      "it under a Muse skills root such as ~/.config/muse/skills/#{invocation.name}."
  end

  private_class_method :candidates, :plugin_candidates, :installed_cache_path,
    :plugin_records, :jailed, :canonical_path, :repository_source,
    :install_hint
end
