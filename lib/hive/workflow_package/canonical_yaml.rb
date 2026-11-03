require "json"

module Hive
  module WorkflowPackage
    module CanonicalYAML
      MANIFEST_KEYS = %w[
        schema name version description author license hive_min_version source
        permissions files release_sha256
      ].freeze
      EXTENSION_PATTERN = /\Ax-[a-z0-9][a-z0-9-]*\z/

      MANIFEST_ORDERS = {
        [] => MANIFEST_KEYS,
        [ "author" ] => %w[name url],
        [ "source" ] => %w[url revision],
        [ "permissions" ] => %w[risk capabilities network_hosts filesystem_read filesystem_write secrets],
        [ "files" ] => [],
        [ "x-hive" ] => %w[tools prompt_assets optional_inputs external_skills mapping_recommendations],
        [ "x-hive", "tools", :item ] => %w[path],
        [ "x-hive", "prompt_assets", :item ] => %w[path],
        [ "x-hive", "optional_inputs", :item ] => %w[name authorized_slots],
        [ "x-hive", "mapping_recommendations", :item ] => %w[slot effort]
      }.freeze
      private_constant :MANIFEST_ORDERS

      module_function

      def dump_manifest(manifest, include_release: true)
        dump(normalize_manifest(manifest, [], include_release: include_release))
      end

      # Reader-only compatibility: pair an exact historical byte match with its
      # unsigned digest input. Producers always use dump_manifest.
      def legacy_v1_release_input(manifest, bytes)
        return unless bytes == legacy_v1_dump(manifest)

        legacy_v1_dump(manifest, include_release: false)
      end

      def dump(value)
        output = +""
        emit(value, output, 0)
        output << "\n" unless output.end_with?("\n")
        output.encode(Encoding::UTF_8)
      end

      def normalize_manifest(value, path, include_release:)
        case value
        when Hash
          unless value.keys.all? { |key| key.is_a?(String) }
            raise ArgumentError, "canonical YAML keys must be strings"
          end
          known = MANIFEST_ORDERS.fetch(path, [])
          keys = (known & value.keys) + (value.keys - known).sort
          keys.each_with_object({}) do |key, result|
            next if path.empty? && key == "release_sha256" && !include_release

            result[key] = normalize_manifest(value[key], path + [ key ], include_release: include_release)
          end
        when Array
          value.map { |child| normalize_manifest(child, path + [ :item ], include_release: include_release) }
        else value
        end
      end
      private_class_method :normalize_manifest

      def legacy_v1_dump(manifest, include_release: true)
        ordered = {}
        MANIFEST_KEYS.each do |key|
          next if key == "release_sha256" && !include_release

          ordered[key] = legacy_v1_value(key, manifest[key]) if manifest.key?(key)
        end
        manifest.keys.grep(EXTENSION_PATTERN).sort.each { |key| ordered[key] = manifest[key] }
        dump(ordered)
      end
      private_class_method :legacy_v1_dump

      def legacy_v1_value(key, value)
        return value unless value.is_a?(Hash)

        order = case key
        when "author" then %w[name url]
        when "source" then %w[url revision]
        when "permissions" then %w[risk capabilities network_hosts filesystem_read filesystem_write secrets]
        else value.keys.sort
        end
        order.each_with_object({}) do |child_key, result|
          result[child_key] = value[child_key] if value.key?(child_key)
        end
      end
      private_class_method :legacy_v1_value

      def emit(value, output, indent)
        case value
        when Hash then emit_hash(value, output, indent)
        when Array then emit_array(value, output, indent)
        else output << scalar(value)
        end
      end

      def emit_hash(value, output, indent)
        if value.empty?
          output << "{}"
          return
        end
        value.each do |key, child|
          output << (" " * indent) << key_text(key) << ":"
          if inline?(child)
            output << " " << inline(child) << "\n"
          else
            output << "\n"
            emit(child, output, indent + 2)
          end
        end
      end

      def emit_array(value, output, indent)
        if value.empty?
          output << "[]"
          return
        end
        value.each do |child|
          output << (" " * indent) << "-"
          if inline?(child)
            output << " " << inline(child) << "\n"
          else
            output << "\n"
            emit(child, output, indent + 2)
          end
        end
      end

      def inline?(value)
        (!value.is_a?(Hash) && !value.is_a?(Array)) || value.empty?
      end

      def inline(value)
        return "{}" if value.is_a?(Hash)
        return "[]" if value.is_a?(Array)

        scalar(value)
      end

      def scalar(value)
        case value
        when String then JSON.generate(value)
        when Integer then value.to_s
        when Float
          raise ArgumentError, "canonical YAML cannot encode non-finite numbers" unless value.finite?
          JSON.generate(value)
        when true then "true"
        when false then "false"
        when nil then "null"
        else raise ArgumentError, "canonical YAML cannot encode #{value.class}"
        end
      end

      def key_text(key)
        raise ArgumentError, "canonical YAML keys must be strings" unless key.is_a?(String)

        key.match?(/\A[a-zA-Z_][a-zA-Z0-9_-]*\z/) ? key : JSON.generate(key)
      end
    end
  end
end
