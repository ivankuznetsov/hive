require "json"
require "hive/skill_check"

module Hive::AgentSupport::Agy::Skills
  extend Hive::AgentSupport::SkillPolicy

  module_function

  # Antigravity CLI discovers skills across workspace customization roots
  # (`.agents/skills`, legacy `.agent/skills`, and workspace plugins), the
  # global Antigravity config root (`~/.gemini/config/skills`), the shared
  # cross-agent root (`~/.agents/skills`), and enabled global plugins under
  # `~/.gemini/config/plugins/`.
  def resolve(invocation, project_root: nil, environment: ENV)
    parsed = Hive::SkillCheck.parse(invocation)
    home = environment["HOME"] || Dir.home
    config_dir = Hive::AgentSupport::Agy.config_directory(environment: environment)
    parse_errors = []
    candidates = candidates(
      parsed, config_dir: config_dir, home: home,
      project_root: project_root, parse_errors: parse_errors
    )
    path = Hive::SkillCheck.first_existing(candidates)
    return resolution(:present, candidates, parse_errors, path:, message: path) if path

    resolution(:missing, candidates, parse_errors, message: install_hint(parsed))
  rescue ArgumentError => error
    resolution(:missing, [], message: "agy: #{error.message}")
  end

  def candidates(invocation, config_dir:, home:, project_root:, parse_errors: [])
    paths = []
    plugin = invocation.plugin ? Hive::SkillCheck.glob_escape(invocation.plugin) : "*"
    name = Hive::SkillCheck.glob_escape(invocation.name)
    if project_root
      %w[.agents .agent].each do |dotdir|
        paths << File.join(project_root, dotdir, "skills", invocation.name, "SKILL.md")
        paths.concat(Dir[File.join(
          project_root, dotdir, "plugins", plugin, "skills", name, "SKILL.md"
        )].sort)
      end
    end
    unless invocation.plugin
      paths << File.join(config_dir, "skills", invocation.name, "SKILL.md")
      paths << File.join(home, ".agents", "skills", invocation.name, "SKILL.md")
    end
    paths.concat(plugin_candidates(invocation, config_dir:, parse_errors:))
    paths
  end

  def plugin_candidates(invocation, config_dir:, parse_errors: [])
    plugins_root = File.join(config_dir, "plugins")
    return [] unless File.directory?(plugins_root)

    config_plugins = plugin_config_map(config_dir, parse_errors: parse_errors)
    directories = if invocation.plugin
      [ invocation.plugin ]
    else
      Dir.children(plugins_root).sort
    end

    directories.filter_map do |dir_name|
      plugin_dir = File.join(plugins_root, dir_name)
      next unless File.directory?(plugin_dir)

      manifest = read_plugin_manifest(plugin_dir, parse_errors: parse_errors)
      next unless manifest
      next unless plugin_enabled?(dir_name, manifest:, config_plugins:)

      candidate = File.join(plugin_dir, "skills", invocation.name, "SKILL.md")
      jailed(candidate, plugins_root, parse_errors: parse_errors)
    end
  rescue SystemCallError => error
    parse_errors << error.message
    []
  end

  def plugin_config_map(config_dir, parse_errors: [])
    path = File.join(config_dir, "config.json")
    document = JSON.parse(File.binread(path))
    raise TypeError, "#{path} must be an object" unless document.is_a?(Hash)

    plugins = document.fetch("plugins", {})
    raise TypeError, "#{path} plugins must be an object" unless plugins.is_a?(Hash)

    plugins
  rescue Errno::ENOENT, Errno::ENOTDIR
    {}
  rescue JSON::ParserError, TypeError, SystemCallError => error
    parse_errors << error.message
    {}
  end

  def read_plugin_manifest(plugin_dir, parse_errors: [])
    path = [ "plugin.json", ".claude-plugin/plugin.json" ]
      .map { |relative| File.join(plugin_dir, relative) }
      .find { |candidate| File.file?(candidate) }
    return nil unless path

    document = JSON.parse(File.binread(path))
    raise TypeError, "#{path} must be an object" unless document.is_a?(Hash)

    document
  rescue JSON::ParserError, TypeError, SystemCallError => error
    parse_errors << error.message
    nil
  end

  def plugin_enabled?(dir_name, manifest:, config_plugins:)
    entry = config_plugins[dir_name]
    if entry.is_a?(Hash) && [ true, false ].include?(entry["enabled"])
      return entry["enabled"]
    end

    manifest["disabled"] != true
  end

  def repository_source(install_path)
    return nil if install_path.to_s.empty?

    [ ".claude-plugin/plugin.json", "plugin.json" ].each do |relative|
      manifest_path = File.join(install_path, relative)
      next unless File.file?(manifest_path)

      document = JSON.parse(File.binread(manifest_path))
      next unless document.is_a?(Hash)

      repository = document["repository"]
      repository = repository["url"] if repository.is_a?(Hash)
      return repository if repository.is_a?(String) && !repository.strip.empty?
    end
    nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def installed_plugin_dir(package_id, config_dir:)
    path = File.join(config_dir, "plugins", package_id.to_s)
    File.directory?(path) ? path : nil
  end

  def live_inventory(bin:, native_spec:, issues:, run:, failure:, **)
    plugins_result = run.call([ bin, "plugin", "list", "--json" ])
    unless plugins_result.success?
      issues << [ "incompatible", "agy plugin inventory failed: #{failure.call(plugins_result)}" ]
    end
    entries = JSON.parse(plugins_result.stdout)
    raise TypeError, "agy plugin list must be an Array" unless entries.is_a?(Array)
    raise TypeError, "agy plugin list entries must be objects" unless entries.all?(Hash)

    entry = entries.find { |candidate| candidate["name"] == native_spec.package }
    install_path = entry && entry["path"]
    {
      "package" => entry && {
        "id" => native_spec.package,
        "version" => entry["version"],
        "enabled" => entry.fetch("enabled", true),
        "install_path" => install_path,
        "source" => repository_source(install_path)
      }.freeze,
      "marketplace" => nil
    }
  end

  def filesystem_inventory(native_spec:, root:, read_json:, **)
    install_path = File.join(root, "plugins", native_spec.package)
    plugin_json_path = File.join(install_path, "plugin.json")
    claude_json_path = File.join(install_path, ".claude-plugin", "plugin.json")
    unless File.file?(plugin_json_path) || File.file?(claude_json_path)
      return { "package" => nil, "marketplace" => nil }.freeze
    end

    manifest = read_json.call(plugin_json_path, {})
    claude_manifest = read_json.call(claude_json_path, {})
    raise TypeError, "#{plugin_json_path} must be an object" unless manifest.is_a?(Hash)
    raise TypeError, "#{claude_json_path} must be an object" unless claude_manifest.is_a?(Hash)

    config_path = File.join(root, "config.json")
    config = read_json.call(config_path, {})
    raise TypeError, "#{config_path} must be an object" unless config.is_a?(Hash)

    config_plugins = config.fetch("plugins", {})
    raise TypeError, "#{config_path} plugins must be an object" unless config_plugins.is_a?(Hash)

    version = manifest["version"] || claude_manifest["version"]
    source = extract_repository(claude_manifest) || extract_repository(manifest)
    {
      "package" => {
        "id" => native_spec.package,
        "version" => version,
        "enabled" => plugin_enabled?(native_spec.package, manifest:, config_plugins:),
        "install_path" => install_path,
        "source" => source
      }.freeze,
      "marketplace" => nil
    }.freeze
  end

  def extract_repository(document)
    return nil unless document.is_a?(Hash)

    repository = document["repository"]
    repository = repository["url"] if repository.is_a?(Hash)
    repository if repository.is_a?(String) && !repository.strip.empty?
  end

  def jailed(path, root, parse_errors: [])
    candidate = canonical_path(path)
    base = canonical_path(root)
    return candidate if candidate == base ||
                          candidate.start_with?(base + File::SEPARATOR)

    parse_errors << "agy plugin path #{candidate.inspect} escapes #{base}"
    nil
  end

  def canonical_path(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path)
  end

  def install_hint(invocation)
    "agy: /#{invocation.name} is not available from an Antigravity CLI skill or plugin root. " \
      "Provision managed skills with `hive setup-agents --agent agy`, " \
      "install a plugin with `agy plugin install <source>`, or place " \
      "it under ~/.gemini/config/skills/#{invocation.name}."
  end

  private_class_method :candidates, :plugin_candidates, :plugin_config_map,
    :read_plugin_manifest, :plugin_enabled?, :extract_repository,
    :jailed, :canonical_path, :install_hint
end
