require "json"
require "digest"
require "time"
require "hive/managed_directory"
require "hive/paths"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Installation-level, agent-readable inventory for the mandatory JobStore
    # upgrade. It is observational status only; the coordinator remains the
    # sole caller of the one converter.
    class RegisteredProjectMigrationStatus
      SCHEMA = "hive-installation-job-schema-migration".freeze
      SCHEMA_VERSION = 2
      FILE_NAME = "refactor-patrol-job-v3.json".freeze
      MAX_BYTES = 2 * 1024 * 1024
      PAYLOAD_KEYS = %w[
        daemon_restart_pending projects registry_digest schema schema_version
        target_schema_version updated_at
      ].freeze
      PROJECT_KEYS = %w[
        current_schema_version error hive_state_path next_retry_at path
        project project_id real_path remediation retryable snapshot_id status
        target_schema_version
      ].freeze
      STATUSES = %w[
        absent current dry_run duplicate failed migrated migration_required
      ].freeze

      def self.registry_digest(entries)
        payload = canonical_registry_value(Array(entries))
        Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(payload)
        )
      end

      def self.canonical_registry_value(value)
        case value
        when Hash
          value.map do |key, item|
            [
              [ key.class.name, key.to_s ],
              canonical_registry_value(item)
            ]
          end.sort_by(&:first)
        when Array
          value.map { |item| canonical_registry_value(item) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          [ value.class.name, value.to_s ]
        end
      end

      def initialize(
        root: File.join(
          Hive::Paths.state_home, "schema-migrations"
        ),
        directory: nil
      )
        @root = File.expand_path(root)
        @directory = directory
      end

      attr_reader :root

      def write(
        results,
        registry_digest:,
        now: Time.now.utc,
        daemon_restart_pending: nil
      )
        existing_pending =
          if daemon_restart_pending.nil?
            safe_read&.fetch("daemon_restart_pending", false)
          else
            daemon_restart_pending
          end
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "target_schema_version" => 3,
          "registry_digest" => registry_digest.to_s,
          "updated_at" => timestamp(now),
          "daemon_restart_pending" => existing_pending == true,
          "projects" => Array(results).map do |result|
            result.to_h.transform_keys(&:to_s).transform_values do |value|
              value.is_a?(Symbol) ? value.to_s : value
            end
          end
        }
        persist(payload)
      end

      def write_daemon_restart_pending(
        payload = nil,
        pending:,
        now: Time.now.utc
      )
        current = payload || read
        raise Hive::ConfigError,
              "installation schema migration status is missing" unless
          current.is_a?(Hash)

        persist(
          current.merge(
            "daemon_restart_pending" => pending == true,
            "updated_at" => timestamp(now)
          )
        )
      end

      def read
        return nil unless root_present?

        bytes = directory.read(
          FILE_NAME, max_bytes: MAX_BYTES, missing: true
        )
        return nil unless bytes

        data = JSON.parse(bytes)
        valid = bytes == canonical(data) && valid_payload?(data)
        raise Hive::ConfigError,
              "installation schema migration status is malformed" unless valid
        data
      rescue JSON::ParserError, EncodingError, ArgumentError,
             SystemCallError, IOError => error
        raise Hive::ConfigError,
              "installation schema migration status is unreadable " \
              "(#{error.class}: #{error.message})"
      end

      def safe_read
        read
      rescue Hive::ConfigError
        nil
      end

      private

      def directory
        @directory ||= Hive::ManagedDirectory.new(
          root: @root,
          label: "installation schema migration status"
        )
      end

      def root_present?
        File.lstat(@root)
        true
      rescue Errno::ENOENT
        false
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def persist(payload)
        bytes = canonical(payload)
        raise Hive::ConfigError,
              "installation schema migration status is malformed" unless
          valid_payload?(payload)
        raise Hive::ConfigError,
              "installation schema migration status is too large" if
          bytes.bytesize > MAX_BYTES

        directory.prepare!
        directory.with_lock("#{FILE_NAME}.lock") do
          directory.atomic_write(FILE_NAME, bytes, mode: 0o600)
        end
        payload
      end

      def valid_payload?(data)
        data.is_a?(Hash) &&
          data.keys.sort == PAYLOAD_KEYS &&
          data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION &&
          data["target_schema_version"] == 3 &&
          data["registry_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
          valid_timestamp?(data["updated_at"]) &&
          [ true, false ].include?(data["daemon_restart_pending"]) &&
          valid_projects?(data["projects"])
      end

      def valid_projects?(projects)
        projects.is_a?(Array) && projects.all? do |project|
          project.is_a?(Hash) &&
            project.keys.sort == PROJECT_KEYS &&
            %w[
              project project_id path real_path hive_state_path remediation
              error
            ].all? { |key| string_or_nil?(project[key]) } &&
            STATUSES.include?(project["status"]) &&
            [ nil, 2, 3 ].include?(project["current_schema_version"]) &&
            project["target_schema_version"] == 3 &&
            snapshot_id?(project["snapshot_id"]) &&
            [ true, false ].include?(project["retryable"]) &&
            (
              project["next_retry_at"].nil? ||
              valid_timestamp?(project["next_retry_at"])
            )
        end
      end

      def string_or_nil?(value)
        value.nil? || value.is_a?(String)
      end

      def snapshot_id?(value)
        value.nil? ||
          value.to_s.match?(/\Asnapshot-[0-9a-f]{64}\z/)
      end

      def valid_timestamp?(value)
        Time.iso8601(value.to_s)
        true
      rescue ArgumentError, TypeError
        false
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "installation schema migration status time is malformed"
      end
    end
  end
end
