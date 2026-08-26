require "json"
require "hive/skill_check"

module Hive::AgentSupport::Grok::Skills
  extend Hive::AgentSupport::SkillPolicy

  module_function

  def resolve(invocation, project_root: nil, environment: ENV)
    parsed = Hive::SkillCheck.parse(invocation)
    home = environment["HOME"] || Dir.home
    config_dir = environment["GROK_HOME"].to_s
    config_dir = File.join(home, ".grok") if config_dir.empty?
    config_dir = File.expand_path(config_dir)
    parse_errors = []
    candidates = candidates(parsed, config_dir:, project_root:, parse_errors:)
    path = Hive::SkillCheck.first_existing(candidates)
    return resolution(:present, candidates, parse_errors, path:, message: path) if path

    resolution(:missing, candidates, parse_errors, message: install_hint(parsed))
  rescue ArgumentError => error
    resolution(:missing, [], message: "grok: #{error.message}")
  end

  def candidates(invocation, config_dir:, project_root:, parse_errors: [])
    paths = []
    plugin = invocation.plugin ? Hive::SkillCheck.glob_escape(invocation.plugin) : "*"
    name = Hive::SkillCheck.glob_escape(invocation.name)
    if project_root
      paths << File.join(project_root, ".grok", "skills", invocation.name, "SKILL.md")
      paths.concat(Dir[File.join(
        project_root, ".grok", "plugins", plugin, "skills", name, "SKILL.md"
      )])
    end
    paths << File.join(config_dir, "skills", invocation.name, "SKILL.md")
    paths.concat(Dir[File.join(config_dir, "plugins", plugin, "skills", name, "SKILL.md")])
    installed_plugin_roots(config_dir, plugin: invocation.plugin, parse_errors:).each do |root|
      candidate = File.join(root, "skills", invocation.name, "SKILL.md")
      path = jailed_skill_path(candidate, root, parse_errors:)
      paths << path if path
    end
    paths
  end

  def installed_plugin_roots(config_dir, plugin: nil, parse_errors: [])
    registry_path = File.join(config_dir, "installed-plugins", "registry.json")
    repos = JSON.parse(File.binread(registry_path)).fetch("repos", {})
    raise TypeError, "#{registry_path} repos must be an object" unless repos.is_a?(Hash)

    state = plugin_state(config_dir)
    repos.filter_map do |repo_key, entry|
      unless entry.is_a?(Hash)
        parse_errors << "#{registry_path} repo #{repo_key.inspect} must be an object"
        next
      end
      plugins = entry["plugins"]
      unless plugins.is_a?(Hash)
        parse_errors << "#{registry_path} repo #{repo_key.inspect} plugins must be an object"
        next
      end
      names = plugins.keys.select { |name| plugin.nil? || name == plugin }
      next if names.empty? || names.none? { |name| plugin_enabled?(config_dir, name, state:) }

      root = entry["path"] || File.join(config_dir, "installed-plugins", repo_key)
      jailed_install_root(root, config_dir, parse_errors:)
    end
  rescue Errno::ENOENT, Errno::ENOTDIR
    []
  rescue JSON::ParserError, TypeError, KeyError, SystemCallError => error
    parse_errors << error.message
    []
  end

  def plugin_state(config_dir)
    content = File.binread(File.join(config_dir, "config.toml"))
    section = content.match(/^\s*\[plugins\]\s*$\n?(.*?)(?=^\s*\[[^\]]+\]\s*$|\z)/m)&.[](1).to_s
    [ toml_string_array(section, "enabled"), toml_string_array(section, "disabled") ]
  rescue Errno::ENOENT, Errno::ENOTDIR
    [ [], [] ]
  end

  def plugin_enabled?(config_dir, plugin_name, state: plugin_state(config_dir))
    enabled, disabled = state
    !plugin_name_match?(disabled, plugin_name) && plugin_name_match?(enabled, plugin_name)
  end

  def toml_string_array(section, key)
    raw = section.match(/^\s*#{Regexp.escape(key)}\s*=\s*(\[.*?\])/m)&.[](1)
    return [] unless raw

    raw.scan(/"((?:\\.|[^"])*)"|'([^']*)'/).map do |double_quoted, single_quoted|
      double_quoted ? JSON.parse(%("#{double_quoted}")) : single_quoted
    end
  rescue JSON::ParserError
    []
  end

  def plugin_name_match?(entries, name)
    entries.any? { |entry| entry == name || entry.end_with?("/#{name}") }
  end

  def jailed_install_root(path, config_dir, parse_errors: [])
    root = canonical_path(File.join(config_dir, "installed-plugins"))
    candidate = canonical_path(path)
    return candidate if contained?(candidate, root)

    parse_errors << "grok plugin path #{candidate.inspect} escapes #{root}"
    nil
  end

  def jailed_skill_path(path, install_root, parse_errors: [])
    root = canonical_path(install_root)
    candidate = canonical_path(path)
    return candidate if contained?(candidate, root)

    parse_errors << "grok skill path #{candidate.inspect} escapes #{root}"
    nil
  end

  def live_inventory(bin:, native_spec:, issues:, run:, failure:, project_root:, **)
    plugins_result = run.call([ bin, "plugin", "list", "--json" ])
    inspect_result = run.call([ bin, "inspect", "--json" ], chdir: project_root)
    unless plugins_result.success?
      issues << [ "incompatible", "grok plugin inventory failed: #{failure.call(plugins_result)}" ]
    end
    unless inspect_result.success?
      issues << [ "incompatible", "grok runtime inspection failed: #{failure.call(inspect_result)}" ]
    end
    plugins = JSON.parse(plugins_result.stdout)
    runtime = JSON.parse(inspect_result.stdout)
    runtime_plugins = runtime.fetch("plugins")
    runtime_skills = runtime.fetch("skills")
    validate_entries!(plugins, "grok plugin list")
    validate_entries!(runtime_plugins, "grok runtime plugins")
    validate_entries!(runtime_skills, "grok runtime skills")

    plugin = plugins.find { |entry| entry["status"] == "installed" && entry["name"] == native_spec.package }
    runtime_plugin = runtime_plugins.find { |entry| entry["name"] == native_spec.package }
    if plugin && runtime_plugin && plugin["path"] && runtime_plugin["path"] &&
       canonical_path(plugin["path"]) != canonical_path(runtime_plugin["path"])
      issues << [
        "conflicting",
        "grok runtime plugin #{native_spec.package} resolves from #{runtime_plugin['path'].inspect}, " \
          "expected installed package #{plugin['path'].inspect}"
      ]
    end
    {
      "package" => plugin && {
        "id" => plugin["name"], "version" => plugin["version"],
        "enabled" => runtime_plugin ? runtime_plugin.fetch("enabled", true) : false,
        "install_path" => plugin["path"], "source" => plugin["source"]
      }.freeze,
      "marketplace" => nil,
      "runtime_skills" => runtime_skills.map do |entry|
        source = entry["source"]
        raise TypeError, "grok runtime skill source must be an object" unless source.is_a?(Hash)

        { "name" => entry["name"], "source_path" => source["path"] }.freeze
      end.freeze
    }
  end

  def filesystem_inventory(native_spec:, root:, **)
    registry_path = File.join(root, "installed-plugins", "registry.json")
    repos = read_registry(registry_path).fetch("repos")
    raise TypeError, "#{registry_path} repos must be an object" unless repos.is_a?(Hash)

    repo_key, entry = repos.find do |_key, candidate|
      candidate.is_a?(Hash) && candidate["plugins"].is_a?(Hash) &&
        candidate["plugins"].key?(native_spec.package)
    end
    return { "package" => nil, "marketplace" => nil }.freeze unless entry

    plugin = entry.fetch("plugins").fetch(native_spec.package)
    unless plugin.is_a?(Hash)
      raise TypeError, "#{registry_path} plugin #{native_spec.package.inspect} must be an object"
    end
    install_path = entry["path"] || File.join(root, "installed-plugins", repo_key)
    install_path = jailed_install_root(install_path, root)
    raise TypeError, "#{registry_path} install path escapes #{root}" unless install_path

    {
      "package" => {
        "id" => native_spec.package, "version" => plugin["version"],
        "enabled" => plugin_enabled?(root, native_spec.package),
        "install_path" => install_path, "source" => entry.dig("kind", "url")
      }.freeze,
      "marketplace" => nil
    }.freeze
  end

  def resolution_issues(invocation:, resolved_path:, native:)
    runtime_skills = native["runtime_skills"] or return []
    name = Hive::SkillCheck.parse(invocation).name
    runtime_skill = runtime_skills.find { |entry| entry["name"] == name }
    return [ [ "conflicting", "grok runtime does not report skill #{name.inspect}" ] ] unless runtime_skill

    source_path = runtime_skill["source_path"]
    unless source_path && expected_resolution_path?(path: source_path, native:)
      return [ [
        "conflicting",
        "grok runtime skill #{name} resolves from #{source_path.inspect}, outside the expected installed package"
      ] ]
    end
    return [] unless resolved_path && canonical_path(source_path) != canonical_path(resolved_path)

    [ [
      "conflicting",
      "grok runtime skill #{name} resolves from #{source_path.inspect}, expected #{resolved_path.inspect}"
    ] ]
  end

  def expected_resolution_path?(path:, native:, **)
    root = native.dig("package", "install_path")
    root && contained?(canonical_path(path), canonical_path(root))
  end

  def read_registry(path)
    JSON.parse(File.binread(path))
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
    { "repos" => {} }
  end

  def validate_entries!(entries, label)
    raise TypeError, "#{label} must be an Array" unless entries.is_a?(Array)
    raise TypeError, "#{label} entries must be objects" unless entries.all?(Hash)
  end

  def canonical_path(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path)
  end

  def contained?(path, root) = path == root || path.start_with?(root + File::SEPARATOR)

  def install_hint(invocation)
    skill = invocation.plugin ? "/#{invocation.plugin}:#{invocation.name}" : "/#{invocation.name}"
    "grok: #{skill} is not available from an enabled Grok skill or plugin. " \
      "Install with `grok plugin install EveryInc/compound-engineering-plugin --trust` " \
      "or enable it with `grok plugin enable compound-engineering`."
  end

  private_class_method :candidates, :plugin_state, :read_registry, :validate_entries!,
    :canonical_path, :contained?, :install_hint
end
