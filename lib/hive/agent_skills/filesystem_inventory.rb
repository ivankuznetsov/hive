require "json"
require "rubygems/version"
require "uri"

require "hive"
require "hive/agent_skills"
require "hive/skill_check"

module Hive
  module AgentSkills
    # Reads the durable state written by supported agent CLIs without launching
    # those CLIs. Some upstream "list" and "version" commands initialize user
    # configuration, so Doctor uses this inventory to remain byte-for-byte
    # read-only. Setup keeps the live CLI inventory because it has explicit
    # consent and needs an immediately refreshed native view after writes.
    class FilesystemInventory
      def initialize
        @json_cache = {}
        @content_cache = {}
        @version_cache = {}
      end

      def inspect(profile:, bin:, native_spec:, root:)
        inventory = case native_spec.provider
        when "claude" then claude_inventory(native_spec, root)
        when "codex" then codex_inventory(native_spec, root)
        when "pi" then pi_inventory(native_spec, root)
        else raise TypeError, "unsupported provider #{native_spec.provider.inspect}"
        end

        {
          "available" => true,
          "bin" => bin,
          "cli_version" => nil,
          "commands" => [].freeze,
          "inventory_source" => "filesystem",
          "package" => inventory.fetch("package"),
          "marketplace" => inventory.fetch("marketplace"),
          "issues" => [].freeze
        }.freeze
      rescue JSON::ParserError, TypeError, KeyError, SystemCallError => e
        {
          "available" => true,
          "bin" => bin,
          "cli_version" => nil,
          "commands" => [].freeze,
          "inventory_source" => "filesystem",
          "package" => nil,
          "marketplace" => nil,
          "issues" => [
            [ "incompatible", "#{profile.name} filesystem inventory is malformed: #{e.message}" ]
          ].freeze
        }.freeze
      end

      private

      def claude_inventory(native_spec, root)
        plugins_path = File.join(root, "plugins", "installed_plugins.json")
        marketplaces_path = File.join(root, "plugins", "known_marketplaces.json")
        plugins_doc = read_optional_json(plugins_path, { "plugins" => {} })
        marketplaces = read_optional_json(marketplaces_path, {})
        settings_path = File.join(root, "settings.json")
        settings = read_optional_json(settings_path, {})
        plugins = plugins_doc.fetch("plugins")
        raise TypeError, "#{plugins_path} plugins must be an object" unless plugins.is_a?(Hash)
        raise TypeError, "#{marketplaces_path} must be an object" unless marketplaces.is_a?(Hash)
        raise TypeError, "#{settings_path} must be an object" unless settings.is_a?(Hash)

        entries = plugins.fetch(native_spec.package, [])
        raise TypeError, "#{plugins_path} entry #{native_spec.package.inspect} must be an array" unless entries.is_a?(Array)
        entry = entries.find { |candidate| candidate.is_a?(Hash) && candidate["scope"] == native_spec.scope } ||
          entries.find { |candidate| candidate.is_a?(Hash) }
        marketplace_entry = marketplaces[native_spec.marketplace]
        if marketplace_entry && !marketplace_entry.is_a?(Hash)
          raise TypeError, "#{marketplaces_path} entry #{native_spec.marketplace.inspect} must be an object"
        end
        enabled_plugins = settings.fetch("enabledPlugins", {})
        unless enabled_plugins.nil? || enabled_plugins.is_a?(Hash)
          raise TypeError, "#{settings_path} enabledPlugins must be an object"
        end
        enabled = enabled_plugins.nil? ? true : enabled_plugins.fetch(native_spec.package, true)
        unless enabled == true || enabled == false
          raise TypeError, "#{settings_path} enabledPlugins entry #{native_spec.package.inspect} must be boolean"
        end

        {
          "package" => entry && {
            "id" => native_spec.package,
            "version" => entry["version"],
            "enabled" => enabled,
            "install_path" => entry["installPath"],
            "source" => nil
          }.freeze,
          "marketplace" => marketplace_entry && {
            "name" => native_spec.marketplace,
            "source" => marketplace_source(marketplace_entry)
          }.freeze
        }.freeze
      end

      def codex_inventory(native_spec, root)
        config_path = File.join(root, "config.toml")
        marketplace_names = [
          "marketplaces.#{native_spec.marketplace}",
          "marketplaces.\"#{native_spec.marketplace}\""
        ]
        plugin_name = "plugins.\"#{native_spec.package}\""
        sections = parse_toml_sections(
          read_optional(config_path),
          selected: marketplace_names + [ plugin_name ]
        )
        marketplace_values = marketplace_names.filter_map { |name| sections[name] }.first
        plugin_values = sections[plugin_name]
        install_path = codex_install_path(root, native_spec)

        {
          "package" => plugin_values && install_path && {
            "id" => native_spec.package,
            "version" => package_version_from(install_path),
            "enabled" => plugin_values.fetch("enabled", true),
            "install_path" => install_path,
            "source" => marketplace_values && marketplace_values["source"]
          }.freeze,
          "marketplace" => marketplace_values && {
            "name" => native_spec.marketplace,
            "source" => marketplace_values["source"]
          }.freeze
        }.freeze
      end

      def pi_inventory(native_spec, root)
        install_path = pi_install_path(root, native_spec.source)
        {
          "package" => install_path && {
            "id" => native_spec.package,
            "version" => package_version_from(install_path),
            "enabled" => true,
            "install_path" => install_path,
            "source" => source_for_pi_install(root, install_path)
          }.freeze,
          "marketplace" => nil
        }.freeze
      end

      def read_optional_json(path, default)
        return @json_cache.fetch(path) if @json_cache.key?(path)

        @json_cache[path] = JSON.parse(File.binread(path))
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
        default
      end

      def read_optional(path)
        return @content_cache.fetch(path) if @content_cache.key?(path)

        @content_cache[path] = File.binread(path)
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
        ""
      end

      def marketplace_source(entry)
        source = entry["source"]
        return source["repo"] || source["url"] || source["source"] if source.is_a?(Hash)

        entry["repo"] || source
      end

      def parse_toml_sections(content, selected:)
        sections = {}
        current = nil
        content.each_line.with_index(1) do |line, line_number|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")
          if (match = stripped.match(/\A\[([^\]]+)\]\z/))
            name = match[1]
            current = selected.include?(name) ? name : nil
            sections[current] ||= {} if current
            next
          end
          next unless current

          match = stripped.match(/\A([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*\z/)
          next unless match
          sections.fetch(current)[match[1]] = parse_toml_scalar(match[2], line_number)
        end
        sections.freeze
      end

      def parse_toml_scalar(value, line_number)
        return true if value == "true"
        return false if value == "false"
        return value[1...-1] if value.start_with?("\"") && value.end_with?("\"")

        raise TypeError, "unsupported config.toml value at line #{line_number}"
      end

      def codex_install_path(root, native_spec)
        plugin = native_spec.package.split("@", 2).first
        base = File.join(root, "plugins", "cache", native_spec.marketplace, plugin)
        return base if package_version_from(base)
        return nil unless File.directory?(base)

        directories = Dir.children(base).sort.filter_map do |entry|
          path = File.join(base, entry)
          next unless File.directory?(path)
          version = package_version_from(path) || entry
          begin
            [ Gem::Version.new(version), path ]
          rescue ArgumentError
            nil
          end
        end
        directories.max_by { |version, path| [ version, path ] }&.last
      end

      def pi_install_path(root, source)
        git_root = File.join(root, "git")
        direct = direct_pi_install_path(git_root, source)
        return direct if direct && File.directory?(direct)
        return nil unless File.directory?(git_root)

        pi_package_roots(git_root).find do |path|
          same_source?(source_for_pi_install(root, path), source)
        end
      end

      def direct_pi_install_path(git_root, source)
        uri = URI.parse(source.to_s)
        return nil unless uri.is_a?(URI::HTTP) && uri.host
        segments = uri.path.delete_prefix("/").sub(/\.git\z/i, "").split("/")
        return nil if segments.empty? || segments.any? { |part| !part.match?(/\A[A-Za-z0-9._-]+\z/) }

        File.join(git_root, uri.host, *segments)
      rescue URI::InvalidURIError
        nil
      end

      def pi_package_roots(git_root)
        Hive::SkillCheck::Pi.git_package_roots(git_root).sort
      end

      def source_for_pi_install(root, install_path)
        git_root = File.join(root, "git")
        jailed = Hive::SkillCheck::Pi.jail_path(install_path, [ git_root ])
        return nil unless jailed

        prefix = File.expand_path(git_root) + File::SEPARATOR
        "https://#{jailed.delete_prefix(prefix)}"
      end

      def package_version_from(root)
        return nil unless root
        return @version_cache.fetch(root) if @version_cache.key?(root)
        return @version_cache[root] = nil unless File.directory?(root)
        candidates = [
          File.join(root, ".claude-plugin", "plugin.json"),
          File.join(root, ".codex-plugin", "plugin.json"),
          File.join(root, "package.json")
        ]
        candidates.each do |path|
          next unless File.file?(path)
          version = JSON.parse(File.binread(path))["version"]
          return @version_cache[root] = version if version
        end
        @version_cache[root] = nil
      end

      def same_source?(actual, expected)
        Hive::AgentSkills.same_source?(actual, expected)
      end
    end
  end
end
