require "time"
require "hive/config"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/registered_project_migration_status"

module Hive
  module RefactorPatrol
    # Shipped upgrade boundary for one Hive installation. It discovers the
    # complete registered-project inventory for that installation, verifies
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
        File.realpath(expanded)
      rescue SystemCallError
        expanded
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
        @project_migrator = project_migrator || method(:migrate_project)
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
        seen = {}
        results = entries.map do |entry|
          migrate_entry(entry, seen, now: time)
        end.freeze
        @last_status_payload = @status_store&.write(
          results,
          registry_digest: @last_registry_digest,
          now: time
        )
        @last_results = results
        @next_run_at = time + @retry_interval
        results
      end

      # The daemon calls the same converter on bounded cadence. No separate
      # recovery state machine is introduced: current/absent projects are
      # cheap probes, and failed projects retry after repair.
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
          next unless result.real_path

          [
            [
              result.project.to_s,
              result.project_id.to_s,
              File.expand_path(result.real_path)
            ],
            true
          ]
        end.to_h
        Array(@registry.call).select do |entry|
          identity = [
            entry.fetch("name").to_s,
            entry.fetch("project_id").to_s,
            self.class.path_key(entry.fetch("path"))
          ]
          admitted.key?(identity)
        rescue KeyError, TypeError, SystemCallError
          false
        end
      end

      private

      def migrate_entry(entry, seen, now:)
        identity = entry_identity(entry)
        duplicate = seen.key?(identity.fetch(:real_path))
        seen[identity.fetch(:real_path)] = true
        return result_for(
          identity,
          status: :duplicate,
          current_schema_version: nil,
          retryable: false
        ) if duplicate
        return result_for(
          identity,
          status: :dry_run,
          current_schema_version: nil,
          retryable: true,
          remediation:
            "run without --dry-run to convert this registered project"
        ) if @dry_run

        migrated = nil
        @migration_lock.call(identity) do
          ownership = @ownership_loader.call(identity)
          unless %w[legacy module].include?(ownership["owner"]) &&
                 ownership["epoch"].is_a?(Integer) &&
                 ownership["epoch"].positive?
            raise Hive::ConfigError,
                  "architecture patrol ownership is unresolved"
          end
          migrated = @project_migrator.call(
            identity, ownership: ownership
          )
        end
        schema = @schema_status.call(identity)
        status = if migrated
          :migrated
        elsif schema.fetch("status") == "current"
          :current
        elsif schema.fetch("status") == "absent"
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
        failed_identity = identity || partial_identity(entry)
        failed_snapshot_id = snapshot_id_after_failure(failed_identity)
        result_for(
          failed_identity,
          status: :failed,
          current_schema_version: nil,
          snapshot_id: failed_snapshot_id,
          retryable: true,
          next_retry_at: timestamp(now + @retry_interval),
          remediation: remediation_for(error, failed_identity),
          error: "#{error.class}: #{error.message}"
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
          entry: entry
        }.freeze
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
          remediation: remediation,
          error: error
        )
      end

      def migrate_project(identity, ownership:)
        Hive::RefactorPatrol::JobStore.migrate_schema!(
          identity.fetch(:real_path),
          hive_state_path: identity.fetch(:hive_state_path),
          project: identity.fetch(:entry),
          ownership: ownership
        )
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
        Hive::RefactorPatrol::JobStore.schema_status(
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
