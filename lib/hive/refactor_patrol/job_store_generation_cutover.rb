require "json"
require "digest"
require "securerandom"
require "time"
require "hive/managed_directory"
require "hive/refactor_patrol/job_schema_tombstone"
require "hive/refactor_patrol/job_schema_transition_lock"
require "hive/refactor_patrol/job_store_schema_migration"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Physical one-way admission from the released v2 JobStore namespace to
    # the v3-only runtime namespace.
    #
    # The source directory is atomically exchanged with a regular-file
    # tombstone before its authoritative inventory is captured. Released
    # writers can therefore mutate neither the sealed source through their
    # normal lexical paths nor the independent v3 target. Conversion then
    # checkpoints inside v3 and admission becomes current only after both its
    # completion marker and the matching tombstone are durable.
    class JobStoreGenerationCutover
      RECORD_SCHEMA =
        "hive-refactor-patrol-job-generation-cutover".freeze
      RECORD_VERSION = 1
      RECORD_NAME = "job-schema-v3-cutover.json".freeze
      MAX_RECORD_BYTES = 32 * 1024
      MAX_JOB_ENTRIES = 8_192
      MAX_JOB_BYTES = 8 * 1024 * 1024
      JOB_ENTRY = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\.json(?:\.lock)?\z/
      RECORD_KEYS = %w[
        archive_name completed_at created_at project_id schema schema_version
        snapshot_id source_inventory_digest source_schema_version status
        target_schema_version transaction_id
      ].freeze
      RECORD_STATUSES = %w[prepared sealed complete].freeze

      def initialize(
        legacy_root:, target_root:, target_version:, validator:,
        corrupt_record:, inconsistent_record:, project:, ownership: nil,
        anchor:, writer_fence:, clock: -> { Time.now.utc },
        nonce: -> { SecureRandom.hex(16) }, migration_factory: nil
      )
        @legacy_root = File.expand_path(legacy_root)
        @target_root = File.expand_path(target_root)
        @target_version = Integer(target_version)
        @validator = validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @project = normalized_project(project)
        @ownership = ownership
        @anchor = File.expand_path(anchor)
        @writer_fence = writer_fence
        @clock = clock
        @nonce = nonce
        @migration_factory = migration_factory
      end

      def run!
        kind = legacy_jobs_type
        return false if kind.nil? && !cutover_record_present?
        return false if native_tombstone?(kind)

        JobSchemaTransitionLock.with_lock(@target_root) do
          kind = legacy_jobs_type
          return false if native_tombstone?(kind)
          if kind.nil?
            inconsistent!(
              "JobStore cutover state exists without a legacy jobs namespace"
            )
          end

          @writer_fence.assert_quiescent!
          record = prepare_record
          record = seal_source!(record, kind: kind)
          copy_sealed_source!(record)
          migrated = schema_migration.run!(transition_lock: false)
          status = schema_migration.status
          unless status.fetch("status") == "current" &&
                 status.fetch("snapshot_id").to_s.match?(
                   JobSchemaTombstone::SNAPSHOT_ID
                 )
            inconsistent!(
              "v3 JobStore is not complete after schema conversion"
            )
          end
          snapshot_id = status.fetch("snapshot_id")
          assert_source_inventory!(
            record,
            sealed_source_inventory(record.fetch("archive_name")),
            message:
              "sealed v2 JobStore changed during schema conversion"
          )
          complete_tombstone!(record, snapshot_id: snapshot_id)
          was_complete = record.fetch("status") == "complete"
          write_record(
            record.merge(
              "status" => "complete",
              "snapshot_id" => snapshot_id,
              "completed_at" =>
                record["completed_at"] || timestamp(@clock.call)
            )
          )
          migrated || !was_complete
        end
      rescue @corrupt_record, @inconsistent_record,
             Hive::ConcurrentRunError
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "refactor patrol JobStore generation cutover is unsafe " \
          "(#{error.class}: #{error.message})",
          path: @target_root
        )
      end

      # Called only for a mutating native-v3 JobStore construction. Read-only
      # inspection never calls this method.
      def ensure_native_namespace!
        JobSchemaTransitionLock.with_lock(@target_root) do
          kind = legacy_jobs_type
          if kind == :directory
            inconsistent!(
              "released JobStore migration is required before v3 mutation"
            )
          end

          target_directory.prepare!
          legacy_directory.prepare!
          if kind.nil?
            tombstone.write(
              origin: "native",
              status: "complete",
              transaction_id: "native-#{@nonce.call}"
            )
          else
            payload = tombstone.read
            if payload.fetch("origin") == "migrated"
              snapshot_id = schema_migration.snapshot_identity
              tombstone.assert_complete!(
                payload, snapshot_id: snapshot_id
              )
            else
              tombstone.assert_complete!(payload, snapshot_id: nil)
            end
          end
          true
        end
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "cannot establish the v3 JobStore namespace " \
          "(#{error.class}: #{error.message})",
          path: @target_root
        )
      end

      def status
        kind = legacy_jobs_type
        if kind == :directory
          return status_payload("migration_required")
        end
        if kind.nil?
          if target_present? || cutover_record_present?
            inconsistent!(
              "v3 JobStore exists without a legacy namespace tombstone"
            )
          end
          return status_payload("absent")
        end

        payload = tombstone.read
        target = schema_migration.status
        if payload.fetch("origin") == "native"
          tombstone.assert_complete!(payload, snapshot_id: nil)
          return target
        end

        snapshot_id = target["snapshot_id"]
        unless payload.fetch("status") == "complete" &&
               target.fetch("status") == "current"
          return target.merge("status" => "migration_required")
        end
        tombstone.assert_complete!(
          payload, snapshot_id: snapshot_id
        )
        record = read_record
        validate_record_tombstone!(record, payload)
        target
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "cannot inspect the JobStore generation cutover " \
          "(#{error.class}: #{error.message})",
          path: @target_root
        )
      end

      def snapshot_identity
        payload = status
        payload["snapshot_id"]
      end

      private

      def prepare_record
        existing = read_record
        return existing if existing

        transaction_suffix = @nonce.call
        unless transaction_suffix.to_s.match?(/\A[0-9a-f]{32}\z/)
          raise ArgumentError, "cutover nonce is malformed"
        end
        record = {
          "schema" => RECORD_SCHEMA,
          "schema_version" => RECORD_VERSION,
          "project_id" => @project.fetch("project_id"),
          "source_schema_version" => 2,
          "target_schema_version" => @target_version,
          "transaction_id" => "migration-#{transaction_suffix}",
          "archive_name" =>
            ".job-schema-v3-source-#{transaction_suffix}",
          "status" => "prepared",
          "snapshot_id" => nil,
          "source_inventory_digest" => nil,
          "created_at" => timestamp(@clock.call),
          "completed_at" => nil
        }
        target_directory.prepare!
        write_record(record)
      end

      def seal_source!(record, kind:)
        archive_name = record.fetch("archive_name")
        transaction_id = record.fetch("transaction_id")
        if kind == :directory
          archive_kind = legacy_directory.entry_type(
            archive_name, missing: true
          )
          if archive_kind.nil?
            tombstone.write(
              archive_name,
              origin: "migrated",
              status: "sealed",
              transaction_id: transaction_id,
              archive_name: archive_name
            )
          elsif archive_kind != :regular
            inconsistent!(
              "JobStore cutover archive name is already occupied"
            )
          else
            prepared = tombstone.read(archive_name)
            validate_record_tombstone!(record, prepared)
          end
          legacy_directory.exchange_directory_with_regular!(
            directory_name: JobSchemaTombstone::FILE_NAME,
            regular_name: archive_name
          )
        elsif kind == :regular
          sealed = tombstone.read
          validate_record_tombstone!(record, sealed)
          unless legacy_directory.entry_type(
            archive_name, missing: true
          ) == :directory
            inconsistent!("sealed v2 JobStore archive is unavailable")
          end
        else
          inconsistent!("legacy JobStore namespace is malformed")
        end

        inventory = sealed_source_inventory(archive_name)
        inventory_digest = source_inventory_digest(inventory)
        if record["source_inventory_digest"] &&
           record["source_inventory_digest"] != inventory_digest
          inconsistent!(
            "sealed v2 JobStore changed after source admission"
          )
        end
        return record if record.fetch("status") == "complete"

        sealed_record = record.merge(
          "status" => "sealed",
          "source_inventory_digest" => inventory_digest
        )
        write_record(sealed_record)
      end

      def copy_sealed_source!(record)
        archive = record.fetch("archive_name")
        source_inventory = sealed_source_inventory(archive)
        assert_source_inventory!(
          record, source_inventory,
          message: "sealed v2 JobStore changed before it was copied"
        )
        source_names = source_inventory.map { |entry| entry.fetch(:name) }
        snapshot_present = target_directory.read(
          JobSchemaSnapshot::MANIFEST,
          max_bytes: JobSchemaSnapshot::MAX_MANIFEST_BYTES,
          missing: true
        )
        target_directory.ensure_directory("jobs")
        target_names = target_directory.each_child(
          "jobs", missing: true
        ).to_a.sort
        unless snapshot_present
          extra = target_names - source_names
          inconsistent!(
            "v3 JobStore contains a job outside the sealed v2 source"
          ) unless extra.empty?

          source_names.each do |name|
            source = legacy_directory.read_with_metadata(
              File.join(archive, name), max_bytes: MAX_JOB_BYTES
            )
            expected = source_inventory.find do |entry|
              entry.fetch(:name) == name
            end
            unless source_metadata(source, name: name) == expected
              inconsistent!(
                "sealed v2 JobStore changed while it was copied"
              )
            end
            target_relative = File.join("jobs", name)
            existing = target_directory.read(
              target_relative, max_bytes: MAX_JOB_BYTES, missing: true
            )
            if existing
              inconsistent!(
                "partial v3 source copy conflicts with sealed v2 bytes"
              ) unless existing == source.fetch(:bytes)
              next
            end
            target_directory.atomic_write(
              target_relative,
              source.fetch(:bytes),
              mode: source.fetch(:mode),
              mtime: source.fetch(:mtime)
            )
          end
        end

        inconsistent!(
          "sealed v2 JobStore changed while it was copied"
        ) unless sealed_source_inventory(archive) == source_inventory
      end

      def sealed_source_inventory(archive)
        names = legacy_directory.each_child(archive).to_a.sort
        unless names.size <= MAX_JOB_ENTRIES * 2 &&
               names.all? { |name| name.match?(JOB_ENTRY) }
          corrupt!("sealed v2 JobStore inventory is malformed")
        end
        names.map do |name|
          source = legacy_directory.read_with_metadata(
            File.join(archive, name), max_bytes: MAX_JOB_BYTES
          )
          source_metadata(source, name: name)
        end.freeze
      end

      def source_metadata(source, name:)
        bytes = source.fetch(:bytes)
        {
          name: name,
          bytes: bytes.bytesize,
          digest: Digest::SHA256.hexdigest(bytes),
          mode: source.fetch(:mode),
          mtime: source.fetch(:mtime).utc.iso8601(9)
        }.freeze
      end

      def source_inventory_digest(inventory)
        Digest::SHA256.hexdigest(canonical(inventory))
      end

      def assert_source_inventory!(record, inventory, message:)
        return if record.fetch("source_inventory_digest") ==
                  source_inventory_digest(inventory)

        inconsistent!(message)
      end

      def complete_tombstone!(record, snapshot_id:)
        current = tombstone.read
        if current.fetch("status") == "complete"
          tombstone.assert_complete!(
            current, snapshot_id: snapshot_id
          )
          return current
        end
        validate_record_tombstone!(record, current)
        tombstone.write(
          origin: "migrated",
          status: "complete",
          transaction_id: record.fetch("transaction_id"),
          archive_name: record.fetch("archive_name"),
          snapshot_id: snapshot_id
        )
      end

      def native_tombstone?(kind)
        return false unless kind == :regular

        payload = tombstone.read
        return false unless payload.fetch("origin") == "native"

        tombstone.assert_complete!(payload, snapshot_id: nil)
        if cutover_record_present?
          inconsistent!(
            "native JobStore tombstone conflicts with migration state"
          )
        end
        unless target_present?
          inconsistent!(
            "native JobStore tombstone exists without the v3 namespace"
          )
        end
        true
      end

      def validate_record_tombstone!(record, payload)
        inconsistent!("JobStore cutover record is missing") unless record
        unless record.fetch("project_id") == payload.fetch("project_id") &&
               record.fetch("transaction_id") ==
                 payload.fetch("transaction_id") &&
               record.fetch("archive_name") ==
                 payload.fetch("archive_name") &&
               record.fetch("target_schema_version") ==
                 payload.fetch("target_schema_version")
          inconsistent!("JobStore cutover identities conflict")
        end
        true
      end

      def read_record
        return nil unless target_present?

        bytes = target_directory.read(
          RECORD_NAME, max_bytes: MAX_RECORD_BYTES, missing: true
        )
        return nil unless bytes

        record = JSON.parse(bytes)
        corrupt!("JobStore cutover record is not canonical") unless
          bytes == canonical(record)
        validate_record!(record)
      rescue JSON::ParserError, EncodingError, ArgumentError => error
        corrupt!(
          "JobStore cutover record is malformed " \
          "(#{error.class}: #{error.message})"
        )
      end

      def write_record(record)
        validate_record!(record)
        target_directory.atomic_write(
          RECORD_NAME, canonical(record), mode: 0o600
        )
        record.freeze
      end

      def validate_record!(record)
        valid = record.is_a?(Hash) &&
          record.keys.sort == RECORD_KEYS &&
          record["schema"] == RECORD_SCHEMA &&
          record["schema_version"] == RECORD_VERSION &&
          record["project_id"] == @project.fetch("project_id") &&
          record["source_schema_version"] == 2 &&
          record["target_schema_version"] == @target_version &&
          (
            record["source_inventory_digest"].nil? ||
            record["source_inventory_digest"].to_s.match?(
              /\A[0-9a-f]{64}\z/
            )
          ) &&
          record["transaction_id"].to_s.match?(
            JobSchemaTombstone::TRANSACTION_ID
          ) &&
          record["transaction_id"].start_with?("migration-") &&
          record["archive_name"].to_s.match?(
            JobSchemaTombstone::ARCHIVE_NAME
          ) &&
          RECORD_STATUSES.include?(record["status"]) &&
          valid_timestamp?(record["created_at"])
        corrupt!("JobStore cutover record has an invalid shape") unless valid

        if record.fetch("status") == "complete"
          corrupt!("completed JobStore cutover record is incomplete") unless
            record["snapshot_id"].to_s.match?(
              JobSchemaTombstone::SNAPSHOT_ID
            ) &&
            record["source_inventory_digest"].to_s.match?(
              /\A[0-9a-f]{64}\z/
            ) &&
            valid_timestamp?(record["completed_at"])
        elsif record.fetch("status") == "sealed"
          corrupt!("sealed JobStore cutover record is incomplete") unless
            record["snapshot_id"].nil? &&
            record["source_inventory_digest"].to_s.match?(
              /\A[0-9a-f]{64}\z/
            ) &&
            record["completed_at"].nil?
        else
          corrupt!("incomplete JobStore cutover record has terminal data") unless
            record["snapshot_id"].nil? &&
            record["source_inventory_digest"].nil? &&
            record["completed_at"].nil?
        end
        record
      rescue KeyError
        corrupt!("JobStore cutover record has an invalid shape")
      end

      def legacy_jobs_type
        return nil unless legacy_root_present?

        legacy_directory.entry_type(
          JobSchemaTombstone::FILE_NAME, missing: true
        )
      end

      def legacy_root_present?
        stat = File.lstat(@legacy_root)
        return true if stat.directory? && !stat.symlink?

        corrupt!("legacy JobStore root is unsafe")
      rescue Errno::ENOENT
        false
      end

      def target_present?
        stat = File.lstat(@target_root)
        return true if stat.directory? && !stat.symlink?

        corrupt!("v3 JobStore root is unsafe")
      rescue Errno::ENOENT
        false
      end

      def cutover_record_present?
        !read_record.nil?
      end

      def schema_migration
        @schema_migration ||= if @migration_factory
          @migration_factory.call(@target_root)
        else
          JobStoreSchemaMigration.new(
            root: @target_root,
            target_version: @target_version,
            validator: @validator,
            corrupt_record: @corrupt_record,
            inconsistent_record: @inconsistent_record,
            project: @project,
            ownership: @ownership,
            anchor: @anchor,
            writer_fence: @writer_fence,
            clock: @clock
          )
        end
      end

      def legacy_directory
        @legacy_directory ||= Hive::ManagedDirectory.new(
          root: @legacy_root,
          anchor: @anchor,
          label: "released refactor patrol JobStore namespace"
        )
      end

      def target_directory
        @target_directory ||= Hive::ManagedDirectory.new(
          root: @target_root,
          anchor: @anchor,
          label: "v3 refactor patrol JobStore namespace"
        )
      end

      def tombstone
        @tombstone ||= JobSchemaTombstone.new(
          directory: legacy_directory,
          project_id: @project.fetch("project_id"),
          target_version: @target_version,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def normalized_project(value)
        data = value.is_a?(Hash) ? value : {}
        project_id = data["project_id"] || data[:project_id]
        name = data["name"] || data[:name]
        if project_id.to_s.empty? || name.to_s.empty?
          raise ArgumentError, "JobStore cutover project identity is incomplete"
        end
        {
          "name" => name.to_s,
          "project_id" => project_id.to_s
        }.freeze
      end

      def status_payload(status)
        {
          "status" => status,
          "source_schema_version" => 2,
          "target_schema_version" => @target_version,
          "snapshot_id" => nil
        }
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        corrupt!("JobStore cutover timestamp is malformed")
      end

      def valid_timestamp?(value)
        text = value.to_s
        !text.empty? && Time.iso8601(text).utc.iso8601(6) == text
      rescue ArgumentError, TypeError
        false
      end

      def corrupt!(message)
        raise @corrupt_record.new(message, path: @target_root)
      end

      def inconsistent!(message)
        raise @inconsistent_record.new(message, path: @target_root)
      end
    end
  end
end
