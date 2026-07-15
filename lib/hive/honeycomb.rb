require "yaml"
require "hive"

module Hive
  module Honeycomb
    SOURCE = "github.com/ivankuznetsov/honeycomb".freeze
    REMOTE_URL = "https://github.com/ivankuznetsov/honeycomb.git".freeze
    CATALOG_VERSION = 1
    MANIFEST_VERSION = 1
    LOCK_VERSION = 1

    class ReferenceError < Hive::Error
      def exit_code = Hive::ExitCodes::USAGE
    end

    class ResolutionError < Hive::Error
      def exit_code = Hive::ExitCodes::USAGE
    end

    class CatalogError < Hive::ConfigError; end
    class ManifestError < Hive::ConfigError; end
    class IntegrityError < Hive::ConfigError; end
    class LockfileError < Hive::ConfigError; end
    class RegistryError < Hive::UnavailableError; end

    class CollisionError < Hive::Error
      def exit_code = Hive::ExitCodes::USAGE
    end

    class ApprovalError < Hive::Error
      def exit_code = Hive::ExitCodes::USAGE
    end

    # Psych accepts duplicate mapping keys by keeping the last value. Registry
    # and lock metadata are authority-bearing, so detect duplicates on the YAML
    # syntax tree before safe loading and reject aliases/classes as usual.
    def self.safe_yaml_load(raw, label:, error_class: CatalogError)
      stream = Psych.parse_stream(raw)
      reject_duplicate_yaml_keys!(stream, label: label, error_class: error_class)
      YAML.safe_load(raw, aliases: false)
    rescue Psych::Exception => e
      raise error_class, "#{label} is not valid YAML: #{e.message}"
    end

    def self.reject_duplicate_yaml_keys!(node, label:, error_class:)
      if node.is_a?(Psych::Nodes::Mapping)
        keys = node.children.each_slice(2).map(&:first).select { |key| key.is_a?(Psych::Nodes::Scalar) }.map(&:value)
        duplicate = keys.group_by(&:itself).find { |_key, values| values.length > 1 }&.first
        raise error_class, "#{label} contains duplicate key #{duplicate.inspect}" if duplicate
      end
      Array(node.children).each do |child|
        reject_duplicate_yaml_keys!(child, label: label, error_class: error_class)
      end
    end
    private_class_method :reject_duplicate_yaml_keys!
  end
end
