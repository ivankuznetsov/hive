require "hive/module_package/manifest"
require "hive/workflow_package/canonical_json"

module Hive
  module ModulePackage
    # Expands the reviewed permission map into the smallest independently
    # consentable units. The manifest key order is part of the presentation
    # contract; set-valued permissions are sorted so CLI and Web see identical
    # atoms regardless of input ordering.
    module PermissionAtoms
      module_function

      def expand(permissions)
        validate_permissions!(permissions)
        Manifest::PERMISSION_KEYS.flat_map do |category|
          value = permissions.fetch(category)
          if category == "repository_write"
            value ? [ atom(category, true) ] : []
          else
            value.sort.map { |entry| atom(category, entry) }
          end
        end.freeze
      end

      def canonicalize(atom)
        unless atom.is_a?(Hash) && atom.keys.all? { |key| key.is_a?(String) } &&
               atom.keys.sort == %w[category value]
          raise Hive::ConfigError, "module permission atom is malformed"
        end

        category = atom.fetch("category")
        value = atom.fetch("value")
        valid = if category == "repository_write"
          value == true
        else
          Manifest::PERMISSION_KEYS.grep_v("repository_write").include?(category) &&
            value.is_a?(String) && !value.empty?
        end
        raise Hive::ConfigError, "module permission atom is malformed" unless valid

        self.atom(category, value)
      end

      def canonical_key(atom)
        Hive::WorkflowPackage::CanonicalJSON.generate(canonicalize(atom))
      end

      def validate_permissions!(permissions)
        unless permissions.is_a?(Hash) &&
               permissions.keys.all? { |key| key.is_a?(String) } &&
               permissions.keys.sort == Manifest::PERMISSION_KEYS.sort
          raise Hive::ConfigError, "module permission atoms require the complete permission map"
        end
        unless [ true, false ].include?(permissions.fetch("repository_write"))
          raise Hive::ConfigError, "module repository_write permission must be boolean"
        end

        Manifest::PERMISSION_KEYS.grep_v("repository_write").each do |category|
          values = permissions.fetch(category)
          valid = values.is_a?(Array) &&
            values.all? { |value| value.is_a?(String) && !value.empty? } &&
            values.uniq == values &&
            (!values.include?("*") || values.length == 1)
          unless valid
            raise Hive::ConfigError,
                  "module permission #{category.inspect} must be a canonical string set"
          end
        end
      end
      private_class_method :validate_permissions!

      def atom(category, value)
        value = value.freeze if value.is_a?(String)
        { "category" => category.freeze, "value" => value }.freeze
      end
    end
  end
end
