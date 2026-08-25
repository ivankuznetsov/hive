require "json"
require "uri"
require "hive/skill_check"

module Hive::AgentSupport::OpenCode::Skills
  Resolution = Hive::SkillCheck::Resolution
  PINNED_COMPOUND_ENGINEERING_PLUGIN =
    "compound-engineering@git+https://github.com/EveryInc/" \
    "compound-engineering-plugin.git#compound-engineering-v3.21.4"

  module_function

  def verify(invocation, project_root: nil, configuration_path: nil,
             configuration: nil, plugins: nil)
    resolve(
      invocation, project_root:, configuration_path:, configuration:, plugins:
    ).then { |resolution| [ resolution.status, resolution.message ] }
  end

  def resolve(invocation, project_root: nil, environment: ENV,
              configuration_path: nil, configuration: nil, plugins: nil)
    inv = Hive::SkillCheck.parse(invocation)
    home = environment["HOME"] || Dir.home
    config_dir = resolve_config_dir(environment, home)
    config_path = configuration_path || environment["OPENCODE_CONFIG"]
    config_path = File.join(config_dir, "opencode.json") if config_path.to_s.empty?
    parse_errors = []
    selected_plugins = if Array(plugins).empty?
      plugin_entries(config_path, parse_errors:, configuration:)
    else
      Array(plugins)
    end
    candidates = build_candidates(
      inv, home:, config_dir:, project_root:, environment:, plugins: selected_plugins
    )
    path = Hive::SkillCheck.first_existing(candidates)
    if path
      if inv.name.start_with?("ce-")
        compound_plugins = selected_plugins.grep(/compound-engineering/)
        if compound_plugins.empty?
          return resolution(:missing, candidates, parse_errors,
                            message: install_hint(inv, config_path))
        end
        expected = compound_plugins.flat_map do |entry|
          plugin_roots(entry, config_dir:, environment:).map do |root|
            File.join(root, "skills", inv.name, "SKILL.md")
          end
        end
        unless expected.any? { |candidate| same_file?(path, candidate) }
          return resolution(
            :shadowed, candidates, parse_errors, path:,
            message: "opencode: /#{inv.name} resolves to #{path}, which " \
                     "shadows the configured Compound Engineering plugin"
          )
        end
      end
      return resolution(:present, candidates, parse_errors, path:, message: path)
    end

    if inv.name.start_with?("ce-") &&
       selected_plugins.include?(PINNED_COMPOUND_ENGINEERING_PLUGIN)
      configured = "configured:#{PINNED_COMPOUND_ENGINEERING_PLUGIN}"
      return resolution(
        :present, candidates, parse_errors, path: configured,
        message: "opencode: /#{inv.name} is provided by the prepared pinned plugin"
      )
    end

    resolution(:missing, candidates, parse_errors, message: install_hint(inv, config_path))
  rescue ArgumentError => e
    resolution(:missing, [], [], message: "opencode: #{e.message}")
  end

  def resolution(status, candidates, parse_errors, path: nil, message:)
    Resolution.new(
      status:, path:, message:, candidates: candidates.freeze,
      parse_errors: parse_errors.freeze
    )
  end

  def build_candidates(inv, home:, config_dir:, project_root:, environment:, plugins:)
    paths = []
    if project_root
      project = File.expand_path(project_root)
      paths << File.join(project, ".opencode", "skills", inv.name, "SKILL.md")
      paths << File.join(project, ".agents", "skills", inv.name, "SKILL.md")
    end
    paths << File.join(config_dir, "skills", inv.name, "SKILL.md")
    paths << File.join(home, ".agents", "skills", inv.name, "SKILL.md")
    paths.concat(Array(plugins).flat_map do |entry|
      plugin_roots(entry, config_dir:, environment:).map do |root|
        File.join(root, "skills", inv.name, "SKILL.md")
      end
    end)
    paths.uniq
  end

  def same_file?(left, right)
    File.exist?(right) && File.realpath(left) == File.realpath(right)
  rescue SystemCallError
    false
  end

  def resolve_config_dir(environment, home)
    configured = environment["OPENCODE_CONFIG_DIR"].to_s
    return File.expand_path(configured) unless configured.empty?

    xdg = environment["XDG_CONFIG_HOME"].to_s
    return File.join(File.expand_path(xdg), "opencode") unless xdg.empty?

    File.join(home, ".config", "opencode")
  end

  def plugin_entries(config_path, parse_errors: [], configuration: nil)
    document = configuration || JSON.parse(File.binread(config_path))
    raise TypeError, "#{config_path} must contain a JSON object" unless document.is_a?(Hash)

    entries = document.fetch("plugin", [])
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) }
      raise TypeError, "#{config_path} plugin must be an array of strings"
    end
    entries
  rescue Errno::ENOENT, Errno::ENOTDIR
    []
  rescue JSON::ParserError, TypeError, SystemCallError => e
    parse_errors << e.message
    []
  end

  def plugin_roots(entry, config_dir:, environment: ENV)
    local = local_plugin_root(entry, config_dir)
    return [ local ] if local

    package = entry.split("@git+", 2).first
    package = package.split("@", 2).first if package.start_with?("@")
    package = "compound-engineering" if package.empty?
    home = environment["HOME"] || Dir.home
    cache = environment["XDG_CACHE_HOME"].to_s
    cache = File.join(home, ".cache") if cache.empty?
    data = environment["XDG_DATA_HOME"].to_s
    data = File.join(home, ".local", "share") if data.empty?
    [
      File.join(cache, "opencode", "node_modules", package),
      File.join(data, "opencode", "node_modules", package),
      File.join(config_dir, "node_modules", package)
    ]
  end

  def local_plugin_root(entry, config_dir)
    path = if entry.start_with?("file://")
      URI(entry).path
    elsif entry.start_with?("/", "./", "../")
      File.absolute_path?(entry) ? entry : File.expand_path(entry, config_dir)
    end
    return unless path

    expanded = File.expand_path(path)
    return expanded if File.directory?(expanded)
    return unless File.file?(expanded)

    marker = File.join(".opencode", "plugins")
    index = expanded.index(marker)
    index ? expanded[0...index].delete_suffix(File::SEPARATOR) : File.dirname(expanded)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def install_hint(inv, config_path)
    "opencode: /#{inv.name} not found in project/user OpenCode skills or " \
      "an explicitly configured plugin. Add #{PINNED_COMPOUND_ENGINEERING_PLUGIN.inspect} " \
      "to the plugin array in #{config_path}."
  end

  def live_inventory(native_spec:, root:, **)
    filesystem_inventory(native_spec:, root:).merge("issues" => [].freeze)
  end

  def filesystem_inventory(native_spec:, root:, **)
    config_path = File.join(root, "opencode.json")
    document = JSON.parse(File.binread(config_path))
    raise TypeError, "#{config_path} must contain an object" unless document.is_a?(Hash)

    plugins = document.fetch("plugin", [])
    unless plugins.is_a?(Array) && plugins.all? { |entry| entry.is_a?(String) }
      raise TypeError, "#{config_path} plugin must be an array of strings"
    end
    configured = plugins.include?(native_spec.package)
    roots = configured ? plugin_roots(native_spec.package, config_dir: root) : []
    install_path = roots.find { |path| File.directory?(path) }
    version = native_spec.package[/#compound-engineering-v([0-9.]+)\z/, 1]
    {
      "package" => configured ? {
        "id" => native_spec.package, "version" => version,
        "enabled" => true, "install_path" => install_path,
        "source" => native_spec.source
      }.freeze : nil,
      "marketplace" => nil
    }.freeze
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
    { "package" => nil, "marketplace" => nil }.freeze
  end

  def environment(profile:, environment:)
    path = profile.support_configuration.configuration_path
    path ? environment.merge("OPENCODE_CONFIG" => path) : environment
  end

  def expected_resolution_path?(path:, native_spec:, native:)
    path == "configured:#{native_spec.package}" &&
      native.dig("package", "id") == native_spec.package
  end
end
