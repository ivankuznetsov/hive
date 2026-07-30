require "time"
require "hive/config"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/registered_project_migration_status"

module Hive
  module RefactorPatrol
    # Shipped upgrade boundary for one exact user profile. It discovers the
    # complete registered-project inventory for that profile, verifies
    # every immutable registration anchor, and invokes the single JobStore
    # converter under the existing Patrol mutation fence.
    class RegisteredProjectMigrationCoordinator
      RETRY_INTERVAL = 3_600
      TARGET_SCHEMA_VERSION = 3
      HOLD_STATUSES = %i[dry_run failed migration_required].freeze
      ADMITTED_STATUSES = %i[absent current migrated].freeze
      Result = Data.define(
        :project, :project_id, :path, :real_path, :hive_state_path,
        :status, :current_schema_version, :target_schema_version,
        :snapshot_id, :retryable, :next_retry_at, :remediation, :error
      )

      def self.path_key(path)
        expanded = File.expand_path(path)
        candidate = expanded
        suffix = []
        loop do
          resolved = File.realpath(candidate)
          return File.join(resolved, *suffix)
        rescue Errno::ENOENT
          parent = File.dirname(candidate)
          return expanded if parent == candidate

          suffix.unshift(File.basename(candidate))
          candidate = parent
        rescue SystemCallError
          return expanded
        end
      end

      def self.registry_digest(entries)
        RegisteredProjectMigrationStatus.registry_digest(entries)
      end

      attr_reader :last_results, :last_status_payload, :last_registry_digest

      def initialize(
        registry: -> {
          Hive::Config.registered_project_entries(
            preserve_invalid: true
          )
        },
        project_migrator: nil,
        schema_status: nil,
        schema_snapshot_id: nil,
        state_present: nil,
        status_store: RegisteredProjectMigrationStatus.new,
        migration_lock: nil,
        ownership_loader: nil,
        dry_run: false,
        retry_interval: RETRY_INTERVAL
      )
        @registry = registry
        # Runtime callers are admission-only by default.  The one-off
        # installed migration must inject the converter explicitly so daemon
        # startup and hourly registry refreshes can never regain v2 mutation
        # authority by constructing this coordinator.
        @project_migrator = project_migrator
        @schema_status = schema_status || method(:project_schema_status)
        @schema_snapshot_id =
          schema_snapshot_id || method(:project_schema_snapshot_id)
        @state_present = state_present
        @status_store = status_store
        @migration_lock = migration_lock || method(:with_migration_lock)
        @ownership_loader = ownership_loader || method(:ownership_for)
        @dry_run = dry_run
        @retry_interval = Integer(retry_interval)
        @last_results = [].freeze
        @last_status_payload = nil
        @next_run_at = nil
      end

      def run(now: Time.now.utc, entries: nil)
        time = utc(now)
        entries = Array(entries || @registry.call)
        @last_registry_digest = self.class.registry_digest(entries)
        results = resolve_entries(entries, now: time).freeze
        @last_status_payload = @status_store&.write(
          results,
          registry_digest: @last_registry_digest,
          now: time
        )
        @last_results = results
        @next_run_at = time + @retry_interval
        results
      end

      # Runtime callers repeat the admission probe on bounded cadence.
      # Conversion remains exclusive to InstalledJobSchemaMigration; a
      # released-schema row stays held until the package-owned retry runs.
      def tick(now: Time.now.utc)
        time = utc(now)
        entries = Array(@registry.call)
        digest = self.class.registry_digest(entries)
        return nil if @next_run_at &&
                      time < @next_run_at &&
                      digest == @last_registry_digest

        run(now: time, entries: entries)
      end

      def eligible_projects
        admitted = @last_results.filter_map do |result|
          next unless ADMITTED_STATUSES.include?(result.status)
          next unless result.real_path && result.hive_state_path

          [ result_identity_key(result), true ]
        end.to_h
        Array(@registry.call).select do |entry|
          admitted.key?(identity_key(entry_identity(entry)))
        rescue KeyError, TypeError, SystemCallError
          false
        end
      end

      # `hive daemon start` deliberately lets the new foreground/detached
      # process own restoration after the user-profile preflight quiesces an
      # older daemon. Clear that durable obligation only after the new daemon
      # has completed construction and is ready to enter its dispatch loop.
      def acknowledge_daemon_restart(now: Time.now.utc)
        payload = @last_status_payload || @status_store&.read
        return payload unless payload.is_a?(Hash)
        return payload unless payload["daemon_restart_pending"] == true

        @last_status_payload =
          @status_store.write_daemon_restart_pending(
            payload,
            pending: false,
            now: utc(now)
          )
      end

      private

      def resolve_entries(entries, now:)
        resolved = Array.new(entries.length)
        identities = entries.each_with_index.filter_map do |entry, index|
          identity = entry_identity(entry)
          [ index, identity ]
        rescue StandardError => error
          resolved[index] = failure_result(
            partial_identity(entry), error, now: now
          )
          nil
        end
        identities.group_by do |_index, identity|
          identity.fetch(:state_path_key)
        end.each_value do |members|
          owner_keys = members.map do |_index, identity|
            identity_key(identity)
          end.uniq
          if owner_keys.length > 1
            members.each do |index, identity|
              resolved[index] = conflicting_state_result(
                identity, now: now
              )
            end
            next
          end

          _first_index, first_identity = members.first
          authoritative = migrate_identity(first_identity, now: now)
          members.each do |index, identity|
            resolved[index] = copy_result(authoritative, identity)
          end
        end
        resolved
      end

      def migrate_identity(identity, now:)
        return result_for(
          identity,
          status: :dry_run,
          current_schema_version: nil,
          retryable: true,
          remediation:
            "run without --dry-run to convert this registered project"
        ) if @dry_run

        return admit_identity(identity, now: now) unless @project_migrator

        migrated = nil
        schema = nil
        @migration_lock.call(identity) do
          ownership = @ownership_loader.call(identity)
          unless %w[legacy module].include?(ownership["owner"]) &&
                 ownership["epoch"].is_a?(Integer) &&
                 ownership["epoch"].positive?
            raise Hive::ConfigError,
                  "architecture patrol ownership is unresolved"
          end
          schema = @schema_status.call(identity)
          unless schema.fetch("status") == "current"
            migrated = @project_migrator.call(
              identity, ownership: ownership
            )
            schema = @schema_status.call(identity)
          end
        end
        status = case schema.fetch("status")
        when "current"
          migrated ? :migrated : :current
        when "absent"
          :absent
        else
          :migration_required
        end
        result_for(
          identity,
          status: status,
          current_schema_version:
            current_schema_version(schema.fetch("status")),
          snapshot_id: schema["snapshot_id"],
          retryable: status == :migration_required,
          next_retry_at:
            status == :migration_required ?
              timestamp(now + @retry_interval) : nil,
          remediation:
            status == :migration_required ?
              "repair the reported project state; Hive retries this same " \
              "migration automatically" : nil
        )
      rescue StandardError => error
        failure_result(identity, error, now: now)
      end

      def admit_identity(identity, now:)
        schema = nil
        @migration_lock.call(identity) do
          schema = @schema_status.call(identity)
        end
        status = case schema.fetch("status")
        when "current"
          :current
        when "absent"
          :absent
        else
          :migration_required
        end
        result_for(
          identity,
          status: status,
          current_schema_version:
            current_schema_version(schema.fetch("status")),
          snapshot_id: schema["snapshot_id"],
          retryable: status == :migration_required,
          next_retry_at:
            status == :migration_required ?
              timestamp(now + @retry_interval) : nil,
          remediation:
            status == :migration_required ?
              "run the install-wide JobStore migration; runtime admission " \
              "does not convert released schemas" : nil
        )
      rescue StandardError => error
        failure_result(identity, error, now: now)
      end

      def failure_result(identity, error, now:)
        failed_snapshot_id = snapshot_id_after_failure(identity)
        result_for(
          identity,
          status: :failed,
          current_schema_version: nil,
          snapshot_id: failed_snapshot_id,
          retryable: true,
          next_retry_at: timestamp(now + @retry_interval),
          remediation: remediation_for(error, identity),
          error:
            RegisteredProjectMigrationStatus.sanitize_diagnostic(
              "#{error.class}: #{error.message}"
            )
        )
      end

      def conflicting_state_result(identity, now:)
        result_for(
          identity,
          status: :failed,
          current_schema_version: nil,
          retryable: true,
          next_retry_at: timestamp(now + @retry_interval),
          remediation:
            "remove or re-register conflicting project identities that share " \
            "this Hive state path; Hive retries automatically",
          error:
            "Hive::ConfigError: multiple registered project identities share " \
            "one Hive state path"
        )
      end

      def copy_result(result, identity)
        result_for(
          identity,
          status: result.status,
          current_schema_version: result.current_schema_version,
          snapshot_id: result.snapshot_id,
          retryable: result.retryable,
          next_retry_at: result.next_retry_at,
          remediation: result.remediation,
          error: result.error
        )
      end

      def entry_identity(entry)
        project = entry.fetch("name").to_s
        project_id = entry.fetch("project_id").to_s
        raise Hive::ConfigError,
              "registered project identity is unresolved" if
          project.empty? || project_id.empty?
        path = File.expand_path(entry.fetch("path"))
        stored_real_path = entry.fetch("real_path")
        unless stored_real_path.is_a?(String) &&
               !stored_real_path.empty?
          raise Hive::ConfigError,
                "registered project canonical path is unresolved"
        end
        current_real_path = File.realpath(path)
        stored_real_path = File.expand_path(stored_real_path)
        unless current_real_path == stored_real_path
          raise Hive::ConfigError,
                "registered project path no longer matches its canonical path"
        end
        hive_state_path = File.expand_path(
          entry.fetch("hive_state_path"), current_real_path
        )
        {
          project: project,
          project_id: project_id,
          path: path,
          real_path: current_real_path,
          hive_state_path: hive_state_path,
          state_path_key: strict_path_key(hive_state_path),
          entry: entry
        }.freeze
      end

      def identity_key(identity)
        [
          identity.fetch(:project).to_s,
          identity.fetch(:project_id).to_s,
          self.class.path_key(identity.fetch(:real_path)),
          self.class.path_key(identity.fetch(:hive_state_path))
        ].freeze
      end

      def result_identity_key(result)
        [
          result.project.to_s,
          result.project_id.to_s,
          self.class.path_key(result.real_path),
          self.class.path_key(result.hive_state_path)
        ].freeze
      end

      def partial_identity(entry)
        entry = entry.is_a?(Hash) ? entry : {}
        path = begin
          File.expand_path(entry["path"])
        rescue StandardError
          nil
        end
        {
          project: entry["name"],
          project_id: entry["project_id"],
          path: path,
          real_path: entry["real_path"],
          hive_state_path: entry["hive_state_path"],
          entry: entry
        }.freeze
      end

      def result_for(identity, status:, current_schema_version:,
                     snapshot_id: nil, retryable:, next_retry_at: nil,
                     remediation: nil, error: nil)
        Result.new(
          project: identity[:project],
          project_id: identity[:project_id],
          path: identity[:path],
          real_path: identity[:real_path],
          hive_state_path: identity[:hive_state_path],
          status: status,
          current_schema_version: current_schema_version,
          target_schema_version: TARGET_SCHEMA_VERSION,
          snapshot_id: snapshot_id,
          retryable: retryable,
          next_retry_at: next_retry_at,
          remediation:
            remediation &&
              RegisteredProjectMigrationStatus.sanitize_diagnostic(
                remediation
              ),
          error:
            error &&
              RegisteredProjectMigrationStatus.sanitize_diagnostic(error)
        )
      end

      def strict_path_key(path)
        candidate = File.expand_path(path)
        suffix = []
        loop do
          resolved = File.realpath(candidate)
          return File.join(resolved, *suffix)
        rescue Errno::ENOENT, Errno::ENOTDIR
          parent = File.dirname(candidate)
          if parent == candidate
            raise Hive::ConfigError,
                  "registered project state path identity is unresolved"
          end
          suffix.unshift(File.basename(candidate))
          candidate = parent
        end
      rescue SystemCallError => error
        raise Hive::ConfigError,
              "registered project state path identity is unavailable " \
              "(#{error.class}: #{error.message})"
      end

      def current_schema_version(status)
        case status
        when "current" then TARGET_SCHEMA_VERSION
        when "migration_required" then 2
        end
      end

      def project_schema_status(identity)
        if @state_present
          present = @state_present.call(identity.fetch(:real_path))
          return {
            "status" => present ? "current" : "absent",
            "snapshot_id" => nil
          }
        end
        Hive::RefactorPatrol::JobStore.schema_admission_status(
          identity.fetch(:real_path),
          hive_state_path: identity.fetch(:hive_state_path),
          project: identity.fetch(:entry)
        )
      end

      def project_schema_snapshot_id(identity)
        Hive::RefactorPatrol::JobStore.schema_snapshot_id(
          identity.fetch(:real_path),
          hive_state_path: identity.fetch(:hive_state_path),
          project: identity.fetch(:entry)
        )
      end

      def snapshot_id_after_failure(identity)
        return nil unless identity[:real_path] &&
                          identity[:hive_state_path] &&
                          identity[:entry].is_a?(Hash)

        status = @schema_status.call(identity)
        value = status["snapshot_id"] if status.is_a?(Hash)
        return value if value

        @schema_snapshot_id.call(identity)
      rescue StandardError
        begin
          @schema_snapshot_id.call(identity)
        rescue StandardError
          nil
        end
      end

      def with_migration_lock(identity, &block)
        Hive::Modules::Migration::Patrols.with_migration_lock(
          identity.fetch(:real_path),
          hive_state_path: identity.fetch(:hive_state_path),
          shared: false,
          &block
        )
      end

      def ownership_for(identity)
        Hive::Modules::Migration::Patrols.ownership_snapshot(
          identity.fetch(:real_path),
          "architecture-patrol",
          hive_state_path: identity.fetch(:hive_state_path)
        )
      end

      def remediation_for(error, identity)
        message = error.message.to_s
        if message.include?("canonical path")
          "re-register #{identity[:project].inspect} from its verified " \
            "canonical path, then wait for automatic retry"
        elsif error.is_a?(Hive::ConcurrentRunError)
          "stop the older Hive daemon or worker; Hive retries automatically"
        else
          "repair the project state or permissions; Hive retries this same " \
            "migration automatically"
        end
      end

      def utc(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "registered project migration time is malformed"
      end

      def timestamp(value)
        utc(value).iso8601(6)
      end
    end
  end
end
