require "json"
require "hive/agent_skills"
require "hive/agent_profiles"
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
        @version_cache = {}
      end

      def inspect(profile:, bin:, native_spec:, root:)
        support = Hive::AgentProfiles.support_for(native_spec.provider)
        inventory = if support
          support::Skills.filesystem_inventory(
            native_spec:, root:, package_version: method(:package_version_from)
          )
        else
          case native_spec.provider
        when "claude" then claude_inventory(native_spec, root)
        else raise TypeError, "unsupported provider #{native_spec.provider.inspect}"
          end
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

      def read_optional_json(path, default)
        return @json_cache.fetch(path) if @json_cache.key?(path)

        @json_cache[path] = JSON.parse(File.binread(path))
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
        default
      end

      def marketplace_source(entry)
        source = entry["source"]
        return source["repo"] || source["url"] || source["source"] if source.is_a?(Hash)

        entry["repo"] || source
      end

      def package_version_from(root)
        return nil unless root
        return @version_cache.fetch(root) if @version_cache.key?(root)
        return @version_cache[root] = nil unless File.directory?(root)
        candidates = Dir[File.join(root, ".*-plugin", "plugin.json")]
        candidates << File.join(root, "package.json")
        candidates.each do |path|
          next unless File.file?(path)
          version = JSON.parse(File.binread(path))["version"]
          return @version_cache[root] = version if version
        end
        @version_cache[root] = nil
      end

    end
  end
end
