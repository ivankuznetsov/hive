module Hive
  module WorkflowPackage
    class SemanticDiff
      Result = Data.define(:metadata, :content, :dependencies, :security, :files, :escalation_reasons) do
        def escalation? = escalation_reasons.any?

        def to_h
          {
            "metadata" => metadata,
            "content" => content,
            "dependencies" => dependencies,
            "security" => security,
            "files" => files,
            "escalation" => escalation?,
            "escalation_reasons" => escalation_reasons
          }
        end
      end

      SECURITY_SETS = %w[tools deny directories commands domains credentials].freeze
      ADDITION_ESCALATIONS = %w[tools directories commands domains credentials].freeze

      def self.compare(old_manifest, new_manifest)
        new(data(old_manifest), data(new_manifest)).compare
      end

      def self.data(value)
        value.respond_to?(:data) ? value.data : value
      end

      def initialize(old_data, new_data)
        @old = old_data
        @new = new_data
      end

      def compare
        escalation_reasons = []
        security = compare_security(escalation_reasons)
        dependencies = compare_dependencies(escalation_reasons)
        Result.new(
          metadata: compare_metadata.freeze,
          content: compare_content.freeze,
          dependencies: dependencies.freeze,
          security: security.freeze,
          files: compare_files.freeze,
          escalation_reasons: escalation_reasons.uniq.sort.freeze
        ).freeze
      end

      private

      def compare_metadata
        %w[version summary author descriptor].each_with_object({}) do |key, changes|
          next if @old[key] == @new[key]

          changes[key] = { "from" => @old[key], "to" => @new[key] }
        end
      end

      def compare_security(escalations)
        old_permissions = @old.fetch("permissions", {})
        new_permissions = @new.fetch("permissions", {})
        SECURITY_SETS.each_with_object({}) do |key, changes|
          diff = set_diff(old_permissions[key], new_permissions[key])
          changes[key] = diff
          if ADDITION_ESCALATIONS.include?(key) && diff.fetch("added").any?
            escalations << "permissions.#{key}.added"
          end
          escalations << "permissions.deny.removed" if key == "deny" && diff.fetch("removed").any?
        end.tap do |changes|
          %w[shell_justification network_justification credential_justification].each do |key|
            next if old_permissions[key] == new_permissions[key]

            changes[key] = { "from" => old_permissions[key], "to" => new_permissions[key] }
          end
        end
      end

      def compare_dependencies(escalations)
        old_dependencies = @old.fetch("dependencies", {})
        new_dependencies = @new.fetch("dependencies", {})
        (old_dependencies.keys | new_dependencies.keys).sort.each_with_object({}) do |key, changes|
          old_value = old_dependencies[key]
          new_value = new_dependencies[key]
          next if old_value == new_value

          if old_value.is_a?(Array) || new_value.is_a?(Array)
            diff = set_diff(old_value, new_value)
            changes[key] = diff
            escalations << "dependencies.#{key}.added" if diff.fetch("added").any?
          else
            changes[key] = { "from" => old_value, "to" => new_value }
            escalations << "dependencies.#{key}.changed"
          end
        end
      end

      def compare_files
        old_files = file_hashes(@old)
        new_files = file_hashes(@new)
        {
          "added" => (new_files.keys - old_files.keys).sort,
          "removed" => (old_files.keys - new_files.keys).sort,
          "modified" => (old_files.keys & new_files.keys).select { |path| old_files[path] != new_files[path] }.sort
        }
      end

      # The update API deliberately reports instruction and descriptor changes
      # without embedding third-party prompt text in terminals, logs, or JSON.
      # Their canonical payload hashes still distinguish every byte change.
      def compare_content
        old_files = file_hashes(@old)
        new_files = file_hashes(@new)
        old_descriptor = @old.fetch("descriptor")
        new_descriptor = @new.fetch("descriptor")
        instruction_paths = (old_files.keys | new_files.keys).grep(%r{\Ainstructions/})
        {
          "descriptor" => {
            "from_path" => old_descriptor,
            "to_path" => new_descriptor,
            "changed" => old_descriptor != new_descriptor || old_files[old_descriptor] != new_files[new_descriptor]
          },
          "instructions" => subset_diff(old_files, new_files, instruction_paths)
        }
      end

      def file_hashes(manifest)
        Array(manifest["files"]).to_h { |entry| [ entry.fetch("path"), entry.fetch("sha256") ] }
      end

      def subset_diff(old_files, new_files, paths)
        {
          "added" => paths.select { |path| !old_files.key?(path) && new_files.key?(path) }.sort,
          "removed" => paths.select { |path| old_files.key?(path) && !new_files.key?(path) }.sort,
          "modified" => paths.select do |path|
            old_files.key?(path) && new_files.key?(path) && old_files[path] != new_files[path]
          end.sort
        }
      end

      def set_diff(old_value, new_value)
        old_values = Array(old_value).map(&:to_s).uniq
        new_values = Array(new_value).map(&:to_s).uniq
        { "added" => (new_values - old_values).sort, "removed" => (old_values - new_values).sort }
      end
    end
  end
end
