require "digest"
require "json"
require "time"

module Hive
  class UserService
    class TransactionJournal
      class Invalid < StandardError; end

      SCHEMA = "hive-user-service-transition"
      VERSION = 1
      MAX_BYTES = 256 * 1024
      TARGET_MAX_BYTES = 1024 * 1024
      APPLY_FORWARD_PHASES = %w[
        prepared backup_stored unit_published manager_reloaded takeover_completed
        activated verified committed
      ].freeze
      APPLY_ROLLBACK_PHASES = %w[
        rollback_selected prior_file_restored prior_manager_restored prior_verified
      ].freeze
      REMOVE_FORWARD_PHASES = %w[
        removal_prepared manager_disabled unit_removed removal_reloaded removal_verified
      ].freeze
      LIFECYCLE_FORWARD_PHASES = %w[
        lifecycle_prepared lifecycle_acted lifecycle_verified lifecycle_committed
      ].freeze
      PHASES_BY_STATE = {
        [ "apply", "forward" ] => APPLY_FORWARD_PHASES,
        [ "apply", "rollback" ] => APPLY_ROLLBACK_PHASES,
        [ "remove", "forward" ] => REMOVE_FORWARD_PHASES,
        [ "lifecycle", "forward" ] => LIFECYCLE_FORWARD_PHASES
      }.freeze
      NEXT_PHASES = {
        [ "apply", "forward", "prepared" ] => %w[backup_stored rollback_selected],
        [ "apply", "forward", "backup_stored" ] => %w[unit_published rollback_selected],
        [ "apply", "forward", "unit_published" ] => %w[manager_reloaded verified rollback_selected],
        [ "apply", "forward", "manager_reloaded" ] => %w[takeover_completed activated rollback_selected],
        [ "apply", "forward", "takeover_completed" ] => %w[activated rollback_selected],
        [ "apply", "forward", "activated" ] => %w[verified rollback_selected],
        [ "apply", "forward", "verified" ] => %w[committed rollback_selected],
        [ "apply", "forward", "committed" ] => [],
        [ "apply", "rollback", "rollback_selected" ] => %w[prior_file_restored],
        [ "apply", "rollback", "prior_file_restored" ] => %w[prior_manager_restored],
        [ "apply", "rollback", "prior_manager_restored" ] => %w[prior_verified],
        [ "apply", "rollback", "prior_verified" ] => [],
        [ "remove", "forward", "removal_prepared" ] => %w[manager_disabled],
        [ "remove", "forward", "manager_disabled" ] => %w[unit_removed],
        [ "remove", "forward", "unit_removed" ] => %w[removal_reloaded],
        [ "remove", "forward", "removal_reloaded" ] => %w[removal_verified],
        [ "remove", "forward", "removal_verified" ] => [],
        [ "lifecycle", "forward", "lifecycle_prepared" ] => %w[lifecycle_acted],
        [ "lifecycle", "forward", "lifecycle_acted" ] => %w[lifecycle_verified],
        [ "lifecycle", "forward", "lifecycle_verified" ] => %w[lifecycle_committed],
        [ "lifecycle", "forward", "lifecycle_committed" ] => []
      }.freeze
      ACTIVATION_PHASES = %w[activated verified committed].freeze
      REQUIRED_KEYS = %w[
        schema schema_version service_name platform target_path operation direction phase
        prior_content prior_digest prior_enabled prior_running desired_digest backup_path
        manager_intent result_kind autostart prior_main_pid prior_process_start
        created_at updated_at
      ].freeze
      OPTIONAL_KEYS = %w[
        restore_from_main_pid restore_from_process_start
        activation_from_main_pid activation_from_process_start
      ].freeze
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
      APPLY_RESULT_KINDS = %w[written upgraded unchanged].freeze
      APPLY_MANAGER_INTENTS = %w[enable restart takeover].freeze
      LIFECYCLE_MANAGER_INTENTS = %w[start stop restart takeover].freeze

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
        validate_target_observation!(data)
        data.freeze
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Invalid, "invalid user-service transition journal: #{error.class}"
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service transition journal: #{error.message}"
      end

      def prepare(operation:, prior_content:, prior_digest:, prior_enabled:, prior_running:,
                  desired_digest:, backup_path:, manager_intent:, result_kind:, autostart:,
                  prior_main_pid: 0, prior_process_start: nil)
        raise Invalid, "pending user-service transition already exists" if read

        operation = operation.to_s
        timestamp = @clock.call.utc.iso8601(6)
        write({
          "schema" => SCHEMA,
          "schema_version" => VERSION,
          "service_name" => @definition.service_name,
          "platform" => @definition.platform.to_s,
          "target_path" => @definition.target_path,
          "operation" => operation,
          "direction" => "forward",
          "phase" => initial_phase(operation),
          "prior_content" => prior_content&.unpack1("H*"),
          "prior_digest" => prior_digest,
          "prior_enabled" => !!prior_enabled,
          "prior_running" => !!prior_running,
          "desired_digest" => desired_digest,
          "backup_path" => backup_path,
          "manager_intent" => manager_intent&.to_s,
          "result_kind" => result_kind.to_s,
          "autostart" => !!autostart,
          "prior_main_pid" => prior_main_pid,
          "prior_process_start" => prior_process_start,
          "restore_from_main_pid" => nil,
          "restore_from_process_start" => nil,
          "activation_from_main_pid" => nil,
          "activation_from_process_start" => nil,
          "created_at" => timestamp,
          "updated_at" => timestamp
        })
      end

      def advance(document, phase:, direction: document.fetch("direction"), activation_process: nil)
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
        if activation_process
          unless operation == "apply" && direction == "forward" && phase == "manager_reloaded"
            raise Invalid, "activation process can only be recorded at manager reload"
          end
          updated = updated.merge(
            "activation_from_main_pid" => activation_process.fetch(:main_pid),
            "activation_from_process_start" => activation_process[:process_start]
          )
        end
        write(updated, expected_document: document)
      end

      def activation_recorded?(document)
        document.fetch("operation") == "apply" &&
          document.fetch("direction") == "forward" &&
          ACTIVATION_PHASES.include?(document.fetch("phase"))
      end

      def record_restore_process(document, main_pid:, process_start:)
        validate_document!(document)
        unless restore_process_recordable?(document)
          raise Invalid, "transition journal cannot record restore process in this state"
        end
        unless document["restore_from_main_pid"].nil?
          raise Invalid, "transition journal restore process is already recorded"
        end

        updated = document.merge(
          "restore_from_main_pid" => main_pid,
          "restore_from_process_start" => process_start,
          "updated_at" => @clock.call.utc.iso8601(6)
        )
        write(updated, expected_document: document)
      end

      def record_activation_process(document, main_pid:, process_start:)
        validate_document!(document)
        unless document.fetch("operation") == "apply" &&
               document.fetch("direction") == "forward" &&
               document.fetch("phase") == "manager_reloaded"
          raise Invalid, "transition journal cannot record activation process in this state"
        end

        updated = document.merge(
          "activation_from_main_pid" => main_pid,
          "activation_from_process_start" => process_start,
          "updated_at" => @clock.call.utc.iso8601(6)
        )
        write(updated, expected_document: document)
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
        snapshot = @directory.read_with_metadata(@name, max_bytes: MAX_BYTES, missing: true)
        return unless snapshot
        raise Invalid, "unsafe user-service transition journal mode" unless snapshot.fetch(:mode) == 0o600

        data = JSON.parse(snapshot.fetch(:bytes))
        validate_document!(data)
        validate_target_observation!(data)
        @directory.unlink(
          @name,
          missing: true,
          expected_digest: Digest::SHA256.hexdigest(snapshot.fetch(:bytes)),
          max_bytes: MAX_BYTES
        )
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Invalid, "invalid user-service transition journal: #{error.class}"
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service transition journal: #{error.message}"
      end

      private

      def write(document, expected_document: nil)
        validate_document!(document)
        options = { mode: 0o600 }
        if expected_document
          expected_bytes = JSON.generate(expected_document) + "\n"
          options[:expected_digest] = Digest::SHA256.hexdigest(expected_bytes)
          options[:max_existing_bytes] = MAX_BYTES
        end
        @directory.atomic_write(@name, JSON.generate(document) + "\n", **options)
        document.freeze
      rescue Hive::ConfigError => error
        raise Invalid, "unsafe user-service transition journal: #{error.message}"
      end

      def validate_document!(data)
        raise Invalid, "transition journal root must be an object" unless data.is_a?(Hash)
        keys = data.keys
        unless (REQUIRED_KEYS - keys).empty? && (keys - REQUIRED_KEYS - OPTIONAL_KEYS).empty?
          raise Invalid, "transition journal fields are not recognized"
        end
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
        validate_prior_state!(data)
        validate_process_identity!(data)
        validate_restore_process_identity!(data)
        validate_activation_process_identity!(data)
        validate_timestamps!(data)
        validate_operation!(data)
        data
      end

      def initial_phase(operation)
        {
          "apply" => "prepared",
          "remove" => "removal_prepared",
          "lifecycle" => "lifecycle_prepared"
        }.fetch(operation) do
          raise Invalid, "transition journal operation is invalid"
        end
      end

      def validate_prior_state!(data)
        encoded = data["prior_content"]
        unless encoded.nil? || (encoded.is_a?(String) && encoded.match?(/\A(?:[0-9a-f]{2})*\z/))
          raise Invalid, "transition journal prior content is invalid"
        end
        digest = data["prior_digest"]
        unless digest.nil? || (digest.is_a?(String) && digest.match?(DIGEST_PATTERN))
          raise Invalid, "transition journal prior_digest is invalid"
        end
        if encoded && digest.nil?
          raise Invalid, "transition journal prior content and digest disagree"
        end
        if encoded.nil? && digest && data["operation"] != "lifecycle"
          raise Invalid, "transition journal prior content and digest disagree"
        end
        if encoded && Digest::SHA256.hexdigest([ encoded ].pack("H*")) != digest
          raise Invalid, "transition journal prior content does not match digest"
        end
      end

      def validate_process_identity!(data)
        pid = data["prior_main_pid"]
        process_start = data["prior_process_start"]
        unless pid.is_a?(Integer) && pid >= 0
          raise Invalid, "transition journal prior main pid is invalid"
        end
        unless process_start.nil? || (process_start.is_a?(String) && !process_start.empty?)
          raise Invalid, "transition journal prior process start is invalid"
        end
        if (pid.zero? && process_start) || (pid.positive? && process_start.nil?)
          raise Invalid, "transition journal prior process identity is incoherent"
        end
      end

      def validate_restore_process_identity!(data)
        pid = data["restore_from_main_pid"]
        process_start = data["restore_from_process_start"]
        unless pid.nil? || (pid.is_a?(Integer) && pid >= 0)
          raise Invalid, "transition journal restore-from main pid is invalid"
        end
        unless process_start.nil? || (process_start.is_a?(String) && !process_start.empty?)
          raise Invalid, "transition journal restore-from process start is invalid"
        end
        if (pid.nil? && process_start) || (pid == 0 && process_start) ||
           (pid&.positive? && process_start.nil?)
          raise Invalid, "transition journal restore-from process identity is incoherent"
        end
        return if pid.nil?

        unless restore_process_recordable?(data)
          raise Invalid, "transition journal restore-from process identity is invalid in this state"
        end
      end

      def validate_activation_process_identity!(data)
        pid = data["activation_from_main_pid"]
        process_start = data["activation_from_process_start"]
        unless pid.nil? || (pid.is_a?(Integer) && pid >= 0)
          raise Invalid, "transition journal activation-from main pid is invalid"
        end
        unless process_start.nil? || (process_start.is_a?(String) && !process_start.empty?)
          raise Invalid, "transition journal activation-from process start is invalid"
        end
        if (pid.nil? && process_start) || (pid == 0 && process_start) ||
           (pid&.positive? && process_start.nil?)
          raise Invalid, "transition journal activation-from process identity is incoherent"
        end
        return if pid.nil?

        forward_phases = %w[manager_reloaded takeover_completed activated verified committed]
        valid_phase = if data.fetch("direction") == "forward"
          forward_phases.include?(data.fetch("phase"))
        else
          APPLY_ROLLBACK_PHASES.include?(data.fetch("phase"))
        end
        unless data.fetch("operation") == "apply" && valid_phase
          raise Invalid, "transition journal activation-from process identity is invalid in this state"
        end
      end

      def restore_process_recordable?(data)
        data.fetch("operation") == "apply" &&
          data.fetch("direction") == "rollback" &&
          data.fetch("prior_running") &&
          APPLY_ROLLBACK_PHASES.index(data.fetch("phase")) >=
            APPLY_ROLLBACK_PHASES.index("prior_file_restored")
      end

      def validate_timestamps!(data)
        created = parse_time(data["created_at"], "created_at")
        updated = parse_time(data["updated_at"], "updated_at")
        raise Invalid, "transition journal timestamps are out of order" if updated < created
      end

      def parse_time(value, field)
        raise Invalid, "transition journal #{field} is invalid" unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        raise Invalid, "transition journal #{field} is invalid"
      end

      def validate_operation!(data)
        case data.fetch("operation")
        when "apply"
          validate_apply!(data)
        when "remove"
          validate_remove!(data)
        when "lifecycle"
          validate_lifecycle!(data)
        else
          raise Invalid, "transition journal operation is invalid"
        end
      end

      def validate_apply!(data)
        desired = data["desired_digest"]
        expected = @definition.content && Digest::SHA256.hexdigest(@definition.content)
        unless desired.is_a?(String) && desired.match?(DIGEST_PATTERN) && desired == expected
          raise Invalid, "transition journal desired digest does not match definition"
        end
        unless APPLY_RESULT_KINDS.include?(data["result_kind"])
          raise Invalid, "transition journal result kind is invalid"
        end
        intent = data["manager_intent"]
        unless intent.nil? || APPLY_MANAGER_INTENTS.include?(intent)
          raise Invalid, "transition journal manager intent is invalid for apply"
        end
        if !data["autostart"] && intent
          raise Invalid, "transition journal manager intent conflicts with autostart"
        end
        validate_apply_backup!(data)
        phase = data.fetch("phase")
        if %w[manager_reloaded takeover_completed activated].include?(phase) && intent.nil?
          raise Invalid, "transition journal manager phase has no intent"
        end
        if phase == "takeover_completed" && intent != "takeover"
          raise Invalid, "transition journal takeover phase has no takeover intent"
        end
      end

      def validate_apply_backup!(data)
        backup = data["backup_path"]
        kind = data.fetch("result_kind")
        if kind == "upgraded"
          unless data["prior_digest"] && valid_backup_path?(backup)
            raise Invalid, "transition journal backup path is invalid"
          end
        elsif !backup.nil?
          raise Invalid, "transition journal backup path is invalid"
        end
        if kind == "written" && data["prior_digest"]
          raise Invalid, "transition journal written result has prior content"
        elsif kind == "unchanged" && data["prior_digest"].nil?
          raise Invalid, "transition journal unchanged result has no prior content"
        end
      end

      def validate_remove!(data)
        valid = data["direction"] == "forward" && data["desired_digest"].nil? &&
          data["backup_path"].nil? && [ nil, "disable" ].include?(data["manager_intent"]) &&
          %w[removed absent].include?(data["result_kind"]) && data["autostart"]
        raise Invalid, "transition journal remove fields are invalid" unless valid
        if data["result_kind"] == "removed" && data["prior_digest"].nil?
          raise Invalid, "transition journal removed result has no prior content"
        end
        if data["result_kind"] == "absent" && data["prior_digest"]
          raise Invalid, "transition journal absent result has prior content"
        end
      end

      def validate_lifecycle!(data)
        desired = data["desired_digest"]
        unless desired.nil? || (desired.is_a?(String) && desired.match?(DIGEST_PATTERN))
          raise Invalid, "transition journal lifecycle digest is invalid"
        end
        valid = data["direction"] == "forward" && data["backup_path"].nil? &&
          LIFECYCLE_MANAGER_INTENTS.include?(data["manager_intent"]) &&
          data["result_kind"] == "unchanged" && data["autostart"] &&
          desired == data["prior_digest"]
        raise Invalid, "transition journal lifecycle fields are invalid" unless valid
      end

      def valid_backup_path?(path)
        return false unless path.is_a?(String) && File.expand_path(path) == path
        return false unless File.dirname(path) == File.dirname(@definition.target_path)

        basename = Regexp.escape(File.basename(@definition.target_path))
        File.basename(path).match?(
          /\A#{basename}\.bak-[0-9]{8}T[0-9]{6}Z(?:-(?:[2-9]|[1-9][0-9]+))?\z/
        )
      rescue ArgumentError
        false
      end

      def validate_target_observation!(data)
        actual = observed_target_digest
        prior = data["prior_digest"]
        desired = data["desired_digest"]
        expected = case [ data.fetch("operation"), data.fetch("direction") ]
        when [ "apply", "forward" ]
          if %w[prepared backup_stored unit_published].include?(data.fetch("phase"))
            [ prior, desired ]
          else
            [ desired ]
          end
        when [ "apply", "rollback" ]
          if data.fetch("phase") == "rollback_selected"
            [ prior, desired ]
          else
            [ prior ]
          end
        when [ "remove", "forward" ]
          if %w[removal_prepared manager_disabled].include?(data.fetch("phase"))
            [ prior, nil ]
          else
            [ nil ]
          end
        when [ "lifecycle", "forward" ]
          [ desired ]
        else
          []
        end
        unless expected.uniq.include?(actual)
          raise Invalid, "transition journal target observation conflicts with phase"
        end
      end

      def observed_target_digest
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(@definition.target_path, flags) do |file|
          before = file.stat
          unless before.file? && before.nlink == 1 && before.size <= TARGET_MAX_BYTES
            raise Invalid, "transition journal target is unsafe"
          end
          bytes = file.read(TARGET_MAX_BYTES + 1)
          after = file.stat
          unchanged = %i[dev ino size mtime ctime nlink].all? do |field|
            before.public_send(field) == after.public_send(field)
          end
          unless unchanged && bytes && bytes.bytesize <= TARGET_MAX_BYTES
            raise Invalid, "transition journal target changed during observation"
          end
          bound = File.lstat(@definition.target_path)
          unless bound.file? && !bound.symlink? && bound.uid == Process.euid &&
                 bound.nlink == 1 && bound.dev == after.dev && bound.ino == after.ino
            raise Invalid, "transition journal target pathname changed during observation"
          end

          Digest::SHA256.hexdigest(bytes)
        end
      rescue Errno::ENOENT
        nil
      rescue Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
        raise Invalid, "transition journal target is unsafe: #{error.class}"
      end
    end
  end
end
