require "digest"
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
      MANAGED_INTENTS = %w[enable restart takeover].freeze
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
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
        expected = @definition.content && Digest::SHA256.hexdigest(@definition.content)
        raise Invalid, "receipt digest does not match definition" unless digest == expected
        options = { mode: 0o600 }
        if (snapshot = @directory.read_with_metadata(@name, max_bytes: MAX_BYTES, missing: true))
          raise Invalid, "unsafe user-service receipt mode" unless snapshot.fetch(:mode) == 0o600

          existing = JSON.parse(snapshot.fetch(:bytes))
          validate_document!(existing)
          options[:expected_digest] = Digest::SHA256.hexdigest(snapshot.fetch(:bytes))
          options[:max_existing_bytes] = MAX_BYTES
        end
        @directory.atomic_write(@name, JSON.generate(data) + "\n", **options)
        data.freeze
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Invalid, "invalid user-service receipt: #{error.class}"
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service receipt: #{error.message}"
      end

      def delete
        snapshot = @directory.read_with_metadata(@name, max_bytes: MAX_BYTES, missing: true)
        return @directory.unlink(@name, missing: true) unless snapshot
        raise Invalid, "unsafe user-service receipt mode" unless snapshot.fetch(:mode) == 0o600

        data = JSON.parse(snapshot.fetch(:bytes))
        validate_document!(data)
        @directory.unlink(
          @name,
          missing: true,
          expected_digest: Digest::SHA256.hexdigest(snapshot.fetch(:bytes)),
          max_bytes: MAX_BYTES
        )
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Invalid, "invalid user-service receipt: #{error.class}"
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
        unless data["desired_digest"].is_a?(String) && data["desired_digest"].match?(DIGEST_PATTERN)
          raise Invalid, "receipt digest is invalid"
        end
        intent = data["manager_intent"]
        if data["mode"] == "managed"
          unless MANAGED_INTENTS.include?(intent)
            raise Invalid, "receipt manager intent is invalid for managed mode"
          end
        elsif !intent.nil?
          raise Invalid, "receipt manager intent conflicts with filesystem-only mode"
        end
        validate_time!(data["verified_at"])
        data
      end

      def validate_time!(value)
        raise Invalid, "receipt verification time is invalid" unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        raise Invalid, "receipt verification time is invalid"
      end
    end
  end
end
