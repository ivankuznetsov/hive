require "json"
require "digest"
require "etc"
require "time"
require "hive/managed_directory"
require "hive/paths"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # One user-profile's agent-readable inventory for the mandatory JobStore
    # upgrade. Machine-wide completion is a separate privileged aggregate;
    # this store remains the retry authority for one exact uid/config/state
    # profile and its registered projects.
    class RegisteredProjectMigrationStatus
      SCHEMA = "hive-user-profile-job-schema-migration".freeze
      SCHEMA_VERSION = 1
      FILE_NAME = "refactor-patrol-job-v3.json".freeze
      MAX_BYTES = 2 * 1024 * 1024
      PAYLOAD_KEYS = %w[
        daemon_restart_pending hive_version projects registry_digest schema
        schema_version target_schema_version updated_at user_profile
      ].freeze
      USER_PROFILE_KEYS = %w[
        config_home home state_home uid username
      ].freeze
      PROJECT_KEYS = %w[
        current_schema_version error hive_state_path next_retry_at path
        project project_id real_path remediation retryable snapshot_id status
        target_schema_version
      ].freeze
      STATUSES = %w[
        absent current dry_run failed migrated migration_required
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

      def self.valid_projects?(projects)
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

      def self.valid_timestamp?(value)
        Time.iso8601(value.to_s)
        true
      rescue ArgumentError, TypeError
        false
      end

      def initialize(
        root: File.join(
          Hive::Paths.state_home, "schema-migrations"
        ),
        directory: nil,
        user_profile: nil
      )
        @root = File.expand_path(root)
        @directory = directory
        @user_profile = user_profile || self.class.current_user_profile
      end

      attr_reader :root, :user_profile

      def self.current_user_profile
        passwd = Etc.getpwuid(Process.uid)
        {
          "username" => passwd.name.to_s,
          "uid" => Process.uid,
          "home" => File.expand_path(Hive::Paths.home),
          "config_home" => File.expand_path(Hive::Paths.config_home),
          "state_home" => File.expand_path(Hive::Paths.state_home)
        }.freeze
      rescue ArgumentError
        {
          "username" => ENV["USER"].to_s,
          "uid" => Process.uid,
          "home" => File.expand_path(Hive::Paths.home),
          "config_home" => File.expand_path(Hive::Paths.config_home),
          "state_home" => File.expand_path(Hive::Paths.state_home)
        }.freeze
      end

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
          "hive_version" => Hive::VERSION,
          "target_schema_version" => 3,
          "registry_digest" => registry_digest.to_s,
          "updated_at" => timestamp(now),
          "daemon_restart_pending" => existing_pending == true,
          "user_profile" => @user_profile,
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
              "user-profile schema migration status is missing" unless
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
              "user-profile schema migration status is malformed" unless valid
        data
      rescue JSON::ParserError, EncodingError, ArgumentError,
             SystemCallError, IOError => error
        raise Hive::ConfigError,
              "user-profile schema migration status is unreadable " \
              "(#{error.class}: #{error.message})"
      end

      def safe_read
        read
      rescue Hive::ConfigError
        nil
      end

      # Pure receipt validation is public so the privileged all-user
      # coordinator can validate a dropped-identity child's JSON without
      # opening that user's status store as root.
      def valid_payload?(
        data,
        hive_version: Hive::VERSION,
        user_profile: @user_profile
      )
        data.is_a?(Hash) &&
          data.keys.sort == PAYLOAD_KEYS &&
          data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION &&
          data["hive_version"] == hive_version &&
          data["target_schema_version"] == 3 &&
          data["registry_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
          self.class.valid_timestamp?(data["updated_at"]) &&
          [ true, false ].include?(data["daemon_restart_pending"]) &&
          data["user_profile"] == user_profile &&
          valid_user_profile?(data["user_profile"]) &&
          self.class.valid_projects?(data["projects"])
      end

      private

      def directory
        @directory ||= Hive::ManagedDirectory.new(
          root: @root,
          label: "user-profile schema migration status"
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
              "user-profile schema migration status is malformed" unless
          valid_payload?(payload)
        raise Hive::ConfigError,
              "user-profile schema migration status is too large" if
          bytes.bytesize > MAX_BYTES

        directory.prepare!
        directory.with_lock("#{FILE_NAME}.lock") do
          directory.atomic_write(FILE_NAME, bytes, mode: 0o600)
        end
        payload
      end

      def valid_user_profile?(profile)
        profile.is_a?(Hash) &&
          profile.keys.sort == USER_PROFILE_KEYS &&
          profile["username"].is_a?(String) &&
          !profile["username"].empty? &&
          profile["uid"].is_a?(Integer) &&
          profile["uid"] >= 0 &&
          %w[home config_home state_home].all? do |key|
            absolute_path?(profile[key])
          end
      end

      def absolute_path?(value)
        value.is_a?(String) &&
          !value.empty? &&
          value.each_byte.none? { |byte| byte < 0x20 || byte == 0x7f } &&
          File.absolute_path(value) == value
      rescue ArgumentError
        false
      end

      def self.string_or_nil?(value)
        value.nil? || value.is_a?(String)
      end
      private_class_method :string_or_nil?

      def self.snapshot_id?(value)
        value.nil? ||
          value.to_s.match?(/\Asnapshot-[0-9a-f]{64}\z/)
      end
      private_class_method :snapshot_id?

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "user-profile schema migration status time is malformed"
      end
    end
  end
end
