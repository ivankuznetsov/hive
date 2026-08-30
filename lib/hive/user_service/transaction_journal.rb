require "json"
require "time"

module Hive
  class UserService
    class TransactionJournal
      class Invalid < StandardError; end

      SCHEMA = "hive-user-service-transition"
      VERSION = 1
      MAX_BYTES = 256 * 1024
      APPLY_FORWARD_PHASES = %w[
        prepared backup_stored unit_published manager_reloaded activated verified
        committed
      ].freeze
      APPLY_ROLLBACK_PHASES = %w[
        rollback_selected prior_file_restored prior_manager_restored prior_verified
      ].freeze
      REMOVE_FORWARD_PHASES = %w[
        removal_prepared manager_disabled unit_removed removal_reloaded removal_verified
      ].freeze
      PHASES_BY_STATE = {
        [ "apply", "forward" ] => APPLY_FORWARD_PHASES,
        [ "apply", "rollback" ] => APPLY_ROLLBACK_PHASES,
        [ "remove", "forward" ] => REMOVE_FORWARD_PHASES
      }.freeze
      NEXT_PHASES = {
        [ "apply", "forward", "prepared" ] => %w[backup_stored unit_published rollback_selected],
        [ "apply", "forward", "backup_stored" ] => %w[unit_published rollback_selected],
        [ "apply", "forward", "unit_published" ] => %w[manager_reloaded activated verified rollback_selected],
        [ "apply", "forward", "manager_reloaded" ] => %w[activated rollback_selected],
        [ "apply", "forward", "activated" ] => %w[verified rollback_selected],
        [ "apply", "forward", "verified" ] => %w[committed],
        [ "apply", "forward", "committed" ] => [],
        [ "apply", "rollback", "rollback_selected" ] => %w[prior_file_restored],
        [ "apply", "rollback", "prior_file_restored" ] => %w[prior_manager_restored],
        [ "apply", "rollback", "prior_manager_restored" ] => %w[prior_verified],
        [ "apply", "rollback", "prior_verified" ] => [],
        [ "remove", "forward", "removal_prepared" ] => %w[manager_disabled unit_removed removal_verified],
        [ "remove", "forward", "manager_disabled" ] => %w[unit_removed removal_verified],
        [ "remove", "forward", "unit_removed" ] => %w[removal_reloaded removal_verified],
        [ "remove", "forward", "removal_reloaded" ] => %w[removal_verified],
        [ "remove", "forward", "removal_verified" ] => []
      }.freeze
      ACTIVATION_PHASES = %w[activated verified committed].freeze
      REQUIRED_KEYS = %w[
        schema schema_version service_name platform target_path operation direction phase
        prior_content prior_digest prior_enabled prior_running desired_digest backup_path
        manager_intent result_kind autostart created_at updated_at
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
        raise Invalid, "unsafe user-service transition journal mode" unless snapshot.fetch(:mode) == 0o600

        data = JSON.parse(snapshot.fetch(:bytes))
        validate_document!(data)
        data.freeze
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Invalid, "invalid user-service transition journal: #{error.class}"
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service transition journal: #{error.message}"
      end

      def prepare(operation:, prior_content:, prior_digest:, prior_enabled:, prior_running:,
                  desired_digest:, backup_path:, manager_intent:, result_kind:, autostart:)
        timestamp = @clock.call.utc.iso8601(6)
        write({
          "schema" => SCHEMA,
          "schema_version" => VERSION,
          "service_name" => @definition.service_name,
          "platform" => @definition.platform.to_s,
          "target_path" => @definition.target_path,
          "operation" => operation.to_s,
          "direction" => "forward",
          "phase" => operation.to_sym == :remove ? "removal_prepared" : "prepared",
          "prior_content" => prior_content&.unpack1("H*"),
          "prior_digest" => prior_digest,
          "prior_enabled" => !!prior_enabled,
          "prior_running" => !!prior_running,
          "desired_digest" => desired_digest,
          "backup_path" => backup_path,
          "manager_intent" => manager_intent&.to_s,
          "result_kind" => result_kind.to_s,
          "autostart" => !!autostart,
          "created_at" => timestamp,
          "updated_at" => timestamp
        })
      end

      def advance(document, phase:, direction: document.fetch("direction"))
        validate_document!(document)
        operation = document.fetch("operation")
        current_direction = document.fetch("direction")
        current_phase = document.fetch("phase")
        direction = direction.to_s
        phase = phase.to_s
        allowed = NEXT_PHASES.fetch([ operation, current_direction, current_phase ])
        unless allowed.include?(phase) &&
               (direction == current_direction ||
                [ operation, current_direction, direction, phase ] ==
                  %w[apply forward rollback rollback_selected])
          raise Invalid,
                "invalid user-service transition from #{current_direction}/#{current_phase} " \
                "to #{direction}/#{phase}"
        end
        updated = document.merge(
          "phase" => phase,
          "direction" => direction,
          "updated_at" => @clock.call.utc.iso8601(6)
        )
        write(updated)
      end

      def activation_recorded?(document)
        document.fetch("operation") == "apply" &&
          document.fetch("direction") == "forward" &&
          ACTIVATION_PHASES.include?(document.fetch("phase"))
      end

      def phase?(document, phase)
        document.fetch("phase") == phase.to_s
      end

      def prior_content(document)
        encoded = document.fetch("prior_content")
        return nil unless encoded
        raise Invalid, "invalid user-service transition prior content" unless encoded.match?(/\A(?:[0-9a-f]{2})*\z/)

        [ encoded ].pack("H*")
      rescue TypeError
        raise Invalid, "invalid user-service transition prior content"
      end

      def delete
        @directory.unlink(@name, missing: true)
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service transition journal: #{error.message}"
      end

      private

      def write(document)
        validate_document!(document)
        @directory.atomic_write(@name, JSON.generate(document) + "\n", mode: 0o600)
        document.freeze
      end

      def validate_document!(data)
        raise Invalid, "transition journal root must be an object" unless data.is_a?(Hash)
        raise Invalid, "transition journal fields are not recognized" unless data.keys.sort == REQUIRED_KEYS.sort
        raise Invalid, "transition journal schema is unsupported" unless data["schema"] == SCHEMA && data["schema_version"] == VERSION
        raise Invalid, "transition journal service does not match" unless data["service_name"] == @definition.service_name
        raise Invalid, "transition journal platform does not match" unless data["platform"] == @definition.platform.to_s
        raise Invalid, "transition journal target does not match" unless data["target_path"] == @definition.target_path
        phases = PHASES_BY_STATE[[ data["operation"], data["direction"] ]]
        raise Invalid, "transition journal operation/direction is invalid" unless phases
        raise Invalid, "transition journal phase is invalid" unless phases.include?(data["phase"])
        unless [ true, false ].include?(data["prior_enabled"]) &&
               [ true, false ].include?(data["prior_running"]) &&
               [ true, false ].include?(data["autostart"])
          raise Invalid, "transition journal booleans are invalid"
        end
        %w[prior_digest desired_digest backup_path manager_intent].each do |key|
          next if data[key].nil? || data[key].is_a?(String)

          raise Invalid, "transition journal #{key} is invalid"
        end
        data
      end
    end
  end
end
