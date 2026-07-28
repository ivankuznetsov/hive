require "hive/module_package/manifest"

module Hive
  module ModulePackage
    class SemanticDiff
      Result = Data.define(:hooks, :settings, :permissions, :files, :permission_expansions) do
        def consent_required? = permission_expansions.any? || hooks.fetch("added").any?

        def to_h
          {
            "hooks" => hooks, "settings" => settings, "permissions" => permissions,
            "files" => files, "permission_expansions" => permission_expansions,
            "consent_required" => consent_required?
          }
        end
      end

      def self.compare(old_value, new_value)
        new(data(old_value), data(new_value)).compare
      end

      def self.data(value)
        return {} if value.nil?
        value.respond_to?(:data) ? value.data : value
      end

      def initialize(old_data, new_data)
        @old = old_data || {}
        @new = new_data || {}
      end

      def compare
        expansions = []
        permission_changes = compare_permissions(expansions)
        Result.new(
          hooks: compare_named("hooks", %w[events schedules target concurrency]).freeze,
          settings: compare_named("settings", %w[type required default values secret]).freeze,
          permissions: permission_changes.freeze,
          files: compare_files.freeze,
          permission_expansions: expansions.sort.freeze
        ).freeze
      end

      private

      def compare_named(key, fields)
        old_rows = rows(@old, key)
        new_rows = rows(@new, key)
        common = old_rows.keys & new_rows.keys
        {
          "added" => (new_rows.keys - old_rows.keys).sort,
          "removed" => (old_rows.keys - new_rows.keys).sort,
          "changed" => common.select do |name|
            fields.any? { |field| old_rows.fetch(name)[field] != new_rows.fetch(name)[field] }
          end.sort
        }
      end

      def rows(data, key)
        value = data[key]
        value = data.dig("contract", key) if !value.is_a?(Array) && data["contract"].is_a?(Hash)
        Array(value).to_h { |row| [ row.fetch(key == "hooks" ? "id" : "name"), row ] }
      end

      def compare_permissions(expansions)
        old_permissions = permissions(@old)
        new_permissions = permissions(@new)
        Manifest::PERMISSION_KEYS.each_with_object({}) do |key, changes|
          if key == "repository_write"
            old_value = !!old_permissions[key]
            new_value = !!new_permissions[key]
            next if old_value == new_value
            changes[key] = { "from" => old_value, "to" => new_value }
            expansions << key if new_value
          else
            old_values = Array(old_permissions[key]).map(&:to_s).uniq
            new_values = Array(new_permissions[key]).map(&:to_s).uniq
            added = (new_values - old_values).sort
            removed = (old_values - new_values).sort
            next if added.empty? && removed.empty?
            changes[key] = { "added" => added, "removed" => removed }
            added.each { |value| expansions << "#{key}:#{value}" }
          end
        end
      end

      def permissions(data)
        data["permissions"] || data.dig("contract", "permissions") || {}
      end

      def compare_files
        old_files = file_map(@old)
        new_files = file_map(@new)
        {
          "added" => (new_files.keys - old_files.keys).sort,
          "removed" => (old_files.keys - new_files.keys).sort,
          "modified" => (old_files.keys & new_files.keys).select { |path| old_files[path] != new_files[path] }.sort
        }
      end

      def file_map(data)
        files = data["files"]
        return {} unless files
        return files if files.is_a?(Hash)
        files.to_h { |entry| [ entry.fetch("path"), entry.fetch("sha256") ] }
      end
    end
  end
end
