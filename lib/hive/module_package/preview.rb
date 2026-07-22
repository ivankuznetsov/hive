require "digest"
require "time"
require "hive/module_package/configuration"
require "hive/module_package/semantic_diff"
require "hive/workflow_package/canonical_json"

module Hive
  module ModulePackage
    class Preview
      SCHEMA_VERSION = 1
      TTL_SECONDS = 600
      OPERATIONS = %w[install update].freeze

      attr_reader :data, :bytes, :digest, :configuration, :diff, :issued_at, :expires_at

      def self.build(operation:, descriptor:, generation:, current:, current_configuration:,
                     settings:, hooks:, grants:, now: Time.now.utc)
        raise Hive::ConfigError, "unsupported module preview operation" unless OPERATIONS.include?(operation)
        if operation == "install" && current
          raise Hive::ConfigError, "module is already installed"
        elsif operation == "update" && !current
          raise Hive::ConfigError, "module is not installed"
        end
        effective_settings = effective_settings_for(
          descriptor, operation: operation, supplied: settings, current: current_configuration
        )
        effective_hooks = effective_hooks_for(
          descriptor, operation: operation, supplied: hooks, current: current_configuration
        )
        configuration = Configuration.build(
          descriptor, generation: generation, settings: effective_settings,
          hooks: effective_hooks, grants: grants
        )
        old_contract = current_configuration&.contract
        diff = SemanticDiff.compare(old_contract, descriptor.to_h)
        new(
          operation: operation, generation: generation, current: current,
          configuration: configuration, diff: diff, now: now
        )
      end

      def initialize(operation:, generation:, current:, configuration:, diff:, now:)
        @configuration = configuration
        @diff = diff
        @issued_at = Time.at(now.to_i, in: "UTC")
        @expires_at = @issued_at + TTL_SECONDS
        @data = {
          "schema_version" => SCHEMA_VERSION,
          "operation" => operation,
          "issued_at" => @issued_at.iso8601(6),
          "expires_at" => @expires_at.iso8601(6),
          "current" => current,
          "candidate" => Configuration.send(:normalize_generation, generation),
          "configuration_digest" => configuration.digest,
          "settings" => configuration.settings,
          "hooks" => configuration.hooks,
          "grants" => configuration.grants,
          "diff" => diff.to_h
        }
        @bytes = Hive::WorkflowPackage::CanonicalJSON.generate(@data).freeze
        @digest = ::Digest::SHA256.hexdigest(@bytes).freeze
        deep_freeze(@data)
        freeze
      end

      def verify!(digest:, current:, now: Time.now.utc)
        raise Hive::ConfigError, "module preview receipt does not match" unless secure_equal?(self.digest, digest.to_s)
        raise Hive::ConfigError, "module preview receipt expired; preview again" if now.utc > expires_at
        unless canonical(current) == canonical(data.fetch("current"))
          raise Hive::ConcurrentRunError.new("module selection changed after preview")
        end
        true
      end

      def receipt
        "#{issued_at.to_i}.#{digest}"
      end

      def self.receipt_parts(receipt)
        match = /\A(?<timestamp>[0-9]{1,12})\.(?<digest>[0-9a-f]{64})\z/.match(receipt.to_s)
        raise Hive::ConfigError, "module preview receipt is malformed" unless match
        [ Time.at(Integer(match[:timestamp]), in: "UTC"), match[:digest] ]
      rescue ArgumentError, RangeError
        raise Hive::ConfigError, "module preview receipt is malformed"
      end

      class << self
        private

        def effective_settings_for(descriptor, operation:, supplied:, current:)
          supplied = stringify_hash(supplied)
          specs = descriptor.settings
          if operation == "install"
            return supplied
          end
          specs.to_h do |spec|
            name = spec.fetch("name")
            value = if supplied.key?(name)
                      supplied[name]
            elsif current&.settings&.key?(name)
                      current.settings[name]
            elsif spec.key?("default")
                      spec["default"]
            else
                      nil
            end
            [ name, value ]
          end
        end

        def effective_hooks_for(descriptor, operation:, supplied:, current:)
          supplied = stringify_hash(supplied)
          return supplied if operation == "install"
          descriptor.hooks.to_h do |hook|
            id = hook.fetch("id")
            enabled = if supplied.key?(id)
                        supplied[id]
            elsif current&.hooks&.key?(id)
                        current.hooks[id]
            else
                        false
            end
            [ id, enabled ]
          end
        end

        def stringify_hash(value)
          raise Hive::ConfigError, "module preview choices must be maps" unless value.is_a?(Hash)
          value.to_h { |key, child| [ key.to_s, child ] }
        end
      end

      private

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def secure_equal?(left, right)
        left.bytesize == right.bytesize && left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
