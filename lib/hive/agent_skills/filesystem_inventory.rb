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
            native_spec:, root:, package_version: method(:package_version_from),
            read_json: method(:read_optional_json)
          )
        else
          raise TypeError, "unsupported provider #{native_spec.provider.inspect}"
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

      def read_optional_json(path, default)
        return @json_cache.fetch(path) if @json_cache.key?(path)

        @json_cache[path] = JSON.parse(File.binread(path))
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
        default
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
