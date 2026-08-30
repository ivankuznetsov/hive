require "json"
require "time"

module Hive
  class UserService
    class AppliedReceipt
      class Invalid < StandardError; end

      SCHEMA = "hive-user-service-applied"
      VERSION = 1
      MAX_BYTES = 64 * 1024
      MODES = %w[managed no_autostart unsupported_autostart].freeze
      REQUIRED_KEYS = %w[
        schema schema_version service_name platform target_path desired_digest mode
        manager_intent verified_at
      ].freeze

      attr_reader :path

      def initialize(directory:, name:, definition:, clock: -> { Time.now.utc })
        @directory = directory
        @name = name
        @path = File.join(directory.root, name)
        @definition = definition
        @clock = clock
      end

      def read
        snapshot = @directory.read_with_metadata(@name, max_bytes: MAX_BYTES, missing: true)
        return nil unless snapshot
        raise Invalid, "unsafe user-service receipt mode" unless snapshot.fetch(:mode) == 0o600

        data = JSON.parse(snapshot.fetch(:bytes))
        validate_document!(data)
        data.freeze
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Invalid, "invalid user-service receipt: #{error.class}"
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service receipt: #{error.message}"
      end

      def write(digest:, mode:, manager_intent:)
        data = {
          "schema" => SCHEMA,
          "schema_version" => VERSION,
          "service_name" => @definition.service_name,
          "platform" => @definition.platform.to_s,
          "target_path" => @definition.target_path,
          "desired_digest" => digest,
          "mode" => mode.to_s,
          "manager_intent" => manager_intent&.to_s,
          "verified_at" => @clock.call.utc.iso8601(6)
        }
        validate_document!(data)
        @directory.atomic_write(@name, JSON.generate(data) + "\n", mode: 0o600)
        data.freeze
      end

      def delete
        @directory.unlink(@name, missing: true)
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service receipt: #{error.message}"
      end

      private

      def validate_document!(data)
        raise Invalid, "receipt root must be an object" unless data.is_a?(Hash)
        raise Invalid, "receipt fields are not recognized" unless data.keys.sort == REQUIRED_KEYS.sort
        raise Invalid, "receipt schema is unsupported" unless data["schema"] == SCHEMA && data["schema_version"] == VERSION
        raise Invalid, "receipt service does not match" unless data["service_name"] == @definition.service_name
        raise Invalid, "receipt platform does not match" unless data["platform"] == @definition.platform.to_s
        raise Invalid, "receipt target does not match" unless data["target_path"] == @definition.target_path
        raise Invalid, "receipt mode is invalid" unless MODES.include?(data["mode"])
        unless data["desired_digest"].is_a?(String) && data["desired_digest"].match?(/\A[0-9a-f]{64}\z/)
          raise Invalid, "receipt digest is invalid"
        end
        data
      end
    end
  end
end
