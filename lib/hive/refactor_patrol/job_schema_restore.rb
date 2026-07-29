require "digest"
require "json"
require "securerandom"
require "time"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/refactor_patrol/job_schema_conversion_proof"
require "hive/refactor_patrol/job_schema_snapshot"
require "hive/refactor_patrol/job_schema_tombstone"
require "hive/refactor_patrol/job_schema_transition_lock"
require "hive/refactor_patrol/job_store_generation_cutover"
require "hive/refactor_patrol/job_store_schema_migration"
require "hive/refactor_patrol/legacy_job_transformer"
require "hive/refactor_patrol/migration_writer_fence"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Explicit offline rollback for one migrated JobStore snapshot. Runtime code
    # remains v3-only: this operator command atomically reactivates exact v2 job
    # bytes for an older binary and then retains the complete v3 generation in a
    # deterministic quarantine. Interrupted restores resume from either side of
    # the exchange without copying unrelated v2-owned state.
    class JobSchemaRestore
      SNAPSHOT_ID = /\Asnapshot-[0-9a-f]{64}\z/
      JOB_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\.json\z/
      JOB_ENTRY =
        /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\.json(?:\.lock)?\z/
      MAX_JOB_ENTRIES = 8_192
      MAX_JOB_FILES = JobStoreSchemaMigration::MAX_JOB_FILES
      MAX_JOB_BYTES = 8 * 1024 * 1024
      MAX_CONVERSION_BYTES = JobSchemaConversionProof::MAX_BYTES
      MAX_MARKER_BYTES = JobStoreSchemaMigration::MAX_MARKER_BYTES
      MAX_CUTOVER_BYTES = JobStoreGenerationCutover::MAX_RECORD_BYTES
      CONVERSION_ROOT = JobSchemaConversionProof::ROOT
      SOURCE_VERSION = 2
      QUARANTINE_ROOT = "job-schema-restore-quarantine".freeze

      Result = Data.define(:snapshot_id, :restored_jobs, :quarantine_path)

      def initialize(target_root:, legacy_root:, target_version:, validator:,
                     corrupt_record:, inconsistent_record:, project_id:,
                     anchor: nil,
                     writer_fence:
                       MigrationWriterFence.new(
                         allow_current_process: false,
                         operation: "JobStore schema restore"
                       ))
        @target_root = File.expand_path(target_root)
        @legacy_root = File.expand_path(legacy_root)
        @target_version = Integer(target_version)
        @validator = validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @project_id = project_id.to_s
        @anchor = File.expand_path(
          anchor || File.dirname(File.dirname(@target_root))
        )
        @writer_fence = writer_fence
      end

      def restore!(snapshot_id:)
        requested = snapshot_id.to_s
        inconsistent!("requested snapshot identity is malformed") unless
          requested.match?(SNAPSHOT_ID)

        JobSchemaTransitionLock.with_lock(@target_root) do
          @writer_fence.assert_quiescent!
          select_candidate_root!(requested)
          manifest = snapshot_store.manifest
          inconsistent!("requested snapshot is unavailable") unless manifest
          unless manifest.fetch("snapshot_id") == requested
            inconsistent!("requested snapshot identity does not match backup")
          end
          validate_candidate!(manifest)
          tombstone = migration_tombstone!(requested)
          validate_sealed_archive!(manifest, tombstone)

          unless restored_namespace_active?
            build_restore_stage!(manifest)
            @writer_fence.assert_quiescent!
            validate_candidate!(manifest)
            validate_restore_stage!(manifest)
            activate_restore!(requested)
          end

          validate_restored_namespace!(manifest)
          quarantine = quarantine_candidate!(requested)
          Result.new(
            snapshot_id: requested,
            restored_jobs: manifest.fetch("entries").size,
            quarantine_path: quarantine
          )
        end
      rescue @corrupt_record, @inconsistent_record,
             Hive::ConcurrentRunError
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "refactor patrol schema restore storage is unsafe " \
          "(#{error.class}: #{error.message})",
          path: @target_root
        )
      end

      private

      def select_candidate_root!(snapshot_id)
        target = safe_directory?(@target_root)
        @selected_cutover_record = nil
        @candidate_root = if target
          @target_root
        else
          select_quarantined_candidate!(snapshot_id)
        end
        @directory = nil
        @snapshot_store = nil
        @cutover_record = nil
      end

      def safe_directory?(path)
        stat = File.lstat(path)
        return true if stat.directory? && !stat.symlink?

        corrupt!("JobStore generation is unsafe", path)
      rescue Errno::ENOENT
        false
      end

      def select_quarantined_candidate!(snapshot_id)
        names = transition_directory.each_child(
          QUARANTINE_ROOT, missing: true
        ).to_a.sort
        unless names.all? do |name|
                 name.match?(JobSchemaTombstone::TRANSACTION_ID)
               end
          corrupt!(
            "JobStore restore quarantine inventory is malformed",
            File.join(File.dirname(@target_root), QUARANTINE_ROOT)
          )
        end

        candidates = names.filter_map do |name|
          relative = File.join(QUARANTINE_ROOT, name)
          unless transition_directory.entry_type(relative) == :directory
            corrupt!(
              "JobStore restore quarantine entry is unsafe",
              File.join(File.dirname(@target_root), relative)
            )
          end
          path = quarantine_path(name)
          record = read_cutover_record(path)
          unless valid_cutover_record_shape?(record)
            corrupt!(
              "JobStore cutover record is malformed",
              File.join(
                path, JobStoreGenerationCutover::RECORD_NAME
              )
            )
          end
          next unless record.fetch("snapshot_id") == snapshot_id

          [ path, record ]
        end
        inconsistent!("live JobStore is absent") if candidates.empty?

        path, record = candidates.max_by do |_candidate_path, candidate_record|
          [
            Time.iso8601(candidate_record.fetch("completed_at")).to_r,
            candidate_record.fetch("transaction_id")
          ]
        end
        @selected_cutover_record = record
        path
      rescue ArgumentError, TypeError, KeyError => error
        corrupt!(
          "JobStore restore quarantine inventory is malformed " \
          "(#{error.class}: #{error.message})",
          File.join(File.dirname(@target_root), QUARANTINE_ROOT)
        )
      end

      def read_cutover_record(root)
        relative = JobStoreGenerationCutover::RECORD_NAME
        managed = Hive::ManagedDirectory.new(
          root: root,
          anchor: @anchor,
          label: "refactor patrol restore cutover record"
        )
        bytes = managed.read(relative, max_bytes: MAX_CUTOVER_BYTES)
        record = JSON.parse(bytes)
        unless record.is_a?(Hash) && bytes == canonical(record)
          corrupt!(
            "JobStore cutover record is malformed",
            File.join(root, relative)
          )
        end
        record
      rescue JSON::ParserError, EncodingError => error
        corrupt!(
          "JobStore cutover record is malformed " \
          "(#{error.class}: #{error.message})",
          File.join(root, relative)
        )
      end

      def valid_cutover_record_shape?(record)
        valid = record.keys.sort ==
          JobStoreGenerationCutover::RECORD_KEYS &&
          record["schema"] == JobStoreGenerationCutover::RECORD_SCHEMA &&
          record["schema_version"] ==
            JobStoreGenerationCutover::RECORD_VERSION &&
          record["project_id"] == @project_id &&
          record["source_schema_version"] == SOURCE_VERSION &&
          record["target_schema_version"] == @target_version &&
          record["status"] == "complete" &&
          record["snapshot_id"].to_s.match?(SNAPSHOT_ID) &&
          record["source_inventory_digest"].to_s.match?(
            /\A[0-9a-f]{64}\z/
          ) &&
          record["transaction_id"].to_s.match?(
            JobSchemaTombstone::TRANSACTION_ID
          ) &&
          record["archive_name"].to_s.match?(
            JobSchemaTombstone::ARCHIVE_NAME
          )
        Time.iso8601(record.fetch("created_at"))
        Time.iso8601(record.fetch("completed_at"))
        valid
      rescue ArgumentError, TypeError, KeyError, NoMethodError
        false
      end

      def validate_candidate!(manifest)
        validate_completion_marker!(manifest)
        validate_cutover_record!(manifest)
        expected_names = manifest.fetch("entries").map do |entry|
          entry.fetch("name")
        end
        jobs = capture_candidate_jobs
        unless jobs.map { |entry| entry.fetch(:name) } == expected_names
          inconsistent!(
            "live JobStore does not have the snapshot's exact job name set"
          )
        end
        conversions = conversion_records
        unless conversions.keys == expected_names
          inconsistent!(
            "conversion ledger does not have the snapshot's exact job name set"
          )
        end

        manifest.fetch("entries").zip(jobs).each do |snapshot_entry, live|
          source = snapshot_store.backup_bytes(snapshot_entry)
          source_data = parse_object(
            source,
            File.join(
              JobSchemaSnapshot::ROOT,
              "jobs",
              snapshot_entry.fetch("name")
            )
          )
          validate_filename!(snapshot_entry.fetch("name"), source_data)
          assert_no_active_workers!(live.fetch(:data), live.fetch(:name))
          unless live.fetch(:version) == @target_version
            inconsistent!(
              "live JobStore contains an unsupported schema version",
              File.join("jobs", live.fetch(:name))
            )
          end
          validate_v3_candidate!(
            live,
            source_data,
            snapshot_entry,
            conversions.fetch(live.fetch(:name))
          )
        end
        true
      end

      def validate_completion_marker!(manifest)
        relative = JobStoreSchemaMigration::MARKER_NAME
        bytes = directory.read(relative, max_bytes: MAX_MARKER_BYTES)
        marker = parse_object(bytes, relative)
        valid = marker.keys.sort ==
          JobStoreSchemaMigration::MARKER_KEYS &&
          marker["schema"] == JobStoreSchemaMigration::MARKER_SCHEMA &&
          marker["schema_version"] ==
            JobStoreSchemaMigration::MARKER_VERSION &&
          marker["source_schema_version"] == SOURCE_VERSION &&
          marker["target_schema_version"] == @target_version &&
          marker["status"] == "complete" &&
          marker["snapshot_id"] == manifest.fetch("snapshot_id") &&
          marker["migrated_jobs"] == manifest.fetch("entries").size
        corrupt!("JobStore migration marker is malformed", relative) unless
          valid && bytes == canonical(marker)
      end

      def validate_cutover_record!(manifest)
        record = @selected_cutover_record ||
                 read_cutover_record(@candidate_root)
        valid = valid_cutover_record_shape?(record) &&
          record["snapshot_id"] == manifest.fetch("snapshot_id") &&
          record["transaction_id"].to_s.start_with?("migration-")
        corrupt!(
          "JobStore cutover record is malformed",
          JobStoreGenerationCutover::RECORD_NAME
        ) unless valid
        @cutover_record = record
      end

      def candidate_transaction_id
        @cutover_record&.fetch("transaction_id") ||
          raise(
            @inconsistent_record.new(
              "JobStore cutover record is unavailable",
              path: @candidate_root || @target_root
            )
          )
      end

      def capture_candidate_jobs
        names = inventory_names(candidate_job_inventory)
        names.filter_map do |name|
          next unless name.end_with?(".json")

          relative = File.join("jobs", name)
          snapshot = directory.read_with_metadata(
            relative, max_bytes: MAX_JOB_BYTES
          )
          data = parse_object(snapshot.fetch(:bytes), relative)
          validate_filename!(name, data)
          {
            name: name,
            data: data,
            bytes: snapshot.fetch(:bytes),
            version: data.fetch("schema_version")
          }.freeze
        end.freeze
      rescue KeyError => error
        corrupt!("live JobStore is missing #{error.key.inspect}")
      end

      def conversion_records
        names = directory.each_child(
          CONVERSION_ROOT, missing: true
        ).to_a.sort
        if names.size > MAX_JOB_ENTRIES ||
           names.any? { |name| !name.match?(JOB_NAME) }
          corrupt!("conversion ledger inventory is malformed", CONVERSION_ROOT)
        end
        names.to_h do |name|
          [
            name,
            directory.read(
              File.join(CONVERSION_ROOT, name),
              max_bytes: MAX_CONVERSION_BYTES
            )
          ]
        end
      end

      def validate_v3_candidate!(live, source_data, snapshot_entry,
                                 proof_bytes)
        @validator.validate_job!(
          live.fetch(:data),
          path: File.join(@candidate_root, "jobs", live.fetch(:name))
        )
        proof_path = File.join(
          @candidate_root, CONVERSION_ROOT, live.fetch(:name)
        )
        conversion_proof.verify!(
          proof_bytes: proof_bytes,
          name: live.fetch(:name),
          snapshot_id: snapshot_store.snapshot_id,
          source_digest: snapshot_entry.fetch("digest"),
          source_data: source_data,
          live_bytes: live.fetch(:bytes),
          path: proof_path
        )
      end

      def assert_no_active_workers!(data, name)
        attempts = Array(data["attempts"])
        claims = Array(data["actions"]).flat_map do |action|
          action.is_a?(Hash) ? Array(action["claims"]) : []
        end
        active = (attempts + claims).find do |entry|
          entry.is_a?(Hash) &&
            %w[claimed running].include?(entry["state"])
        end
        return unless active

        raise Hive::ConcurrentRunError.new(
          "all refactor patrol workers must be durably quiescent before " \
          "JobStore schema restore",
          holder: {
            pid: active["pid"] || active["owner_pid"],
            process_start_time:
              active["process_start_time"] ||
              active["owner_process_start_time"]
          },
          lock_path: File.join(
            @candidate_root, "jobs", "#{name}.lock"
          )
        )
      end

      def migration_tombstone!(snapshot_id)
        relative =
          if restored_namespace_active?
            restore_stage_name(candidate_transaction_id)
          else
            JobSchemaTombstone::FILE_NAME
          end
        payload = tombstone.read(relative)
        tombstone.assert_complete!(payload, snapshot_id: snapshot_id)
        inconsistent!("native JobStore has no released v2 snapshot") unless
          payload.fetch("origin") == "migrated"
        payload
      end

      def validate_sealed_archive!(manifest, payload)
        archive = payload.fetch("archive_name")
        unless legacy_directory.entry_type(archive, missing: true) == :directory
          inconsistent!("sealed v2 JobStore archive is unavailable")
        end
        names = legacy_directory.each_child(archive).to_a.sort
        JobStoreSchemaMigration.validate_job_inventory_names!(names)
        json_names = names.select { |name| name.end_with?(".json") }
        expected = manifest.fetch("entries").map { |entry| entry.fetch("name") }
        unless json_names == expected
          inconsistent!("sealed v2 JobStore archive inventory conflicts")
        end
        manifest.fetch("entries").each do |entry|
          snapshot = legacy_directory.read_with_metadata(
            File.join(archive, entry.fetch("name")),
            max_bytes: MAX_JOB_BYTES
          )
          verify_v2_snapshot!(snapshot, entry, "sealed v2 archive")
        end
      end

      def build_restore_stage!(manifest)
        stage = restore_stage_name(candidate_transaction_id)
        kind = legacy_directory.entry_type(stage, missing: true)
        if kind && kind != :directory
          inconsistent!("restore stage is not a directory")
        end
        legacy_directory.ensure_directory(stage) unless kind
        names = legacy_directory.each_child(stage).to_a.sort
        expected = manifest.fetch("entries").map { |entry| entry.fetch("name") }
        unless (names - expected).empty? &&
               names.all? { |name| name.match?(JOB_NAME) }
          inconsistent!("restore stage contains an unknown job")
        end

        manifest.fetch("entries").each do |entry|
          relative = File.join(stage, entry.fetch("name"))
          existing = legacy_directory.read_with_metadata(
            relative, max_bytes: MAX_JOB_BYTES, missing: true
          )
          if existing
            verify_v2_snapshot!(existing, entry, "restore stage")
            next
          end
          legacy_directory.atomic_write(
            relative,
            snapshot_store.backup_bytes(entry),
            mode: entry.fetch("mode"),
            mtime: Time.iso8601(entry.fetch("mtime"))
          )
        end
      end

      def validate_restore_stage!(manifest)
        stage = restore_stage_name(candidate_transaction_id)
        names = legacy_directory.each_child(stage).to_a.sort
        expected = manifest.fetch("entries").map { |entry| entry.fetch("name") }
        inconsistent!("restore stage job inventory conflicts") unless
          names == expected
        manifest.fetch("entries").each do |entry|
          snapshot = legacy_directory.read_with_metadata(
            File.join(stage, entry.fetch("name")),
            max_bytes: MAX_JOB_BYTES
          )
          verify_v2_snapshot!(snapshot, entry, "restore stage")
        end
      end

      def activate_restore!(_snapshot_id)
        legacy_directory.exchange_directory_with_regular!(
          directory_name: restore_stage_name(candidate_transaction_id),
          regular_name: JobSchemaTombstone::FILE_NAME
        )
      end

      def restored_namespace_active?
        legacy_directory.entry_type(
          JobSchemaTombstone::FILE_NAME, missing: true
        ) == :directory
      end

      def validate_restored_namespace!(manifest)
        unless restored_namespace_active?
          inconsistent!("released v2 JobStore was not activated")
        end
        names = legacy_directory.each_child(
          JobSchemaTombstone::FILE_NAME
        ).to_a.sort
        expected = manifest.fetch("entries").map { |entry| entry.fetch("name") }
        inconsistent!("restored v2 JobStore inventory conflicts") unless
          names == expected
        manifest.fetch("entries").each do |entry|
          snapshot = legacy_directory.read_with_metadata(
            File.join(JobSchemaTombstone::FILE_NAME, entry.fetch("name")),
            max_bytes: MAX_JOB_BYTES
          )
          verify_v2_snapshot!(snapshot, entry, "restored v2 JobStore")
        end
      end

      def verify_v2_snapshot!(snapshot, entry, label)
        bytes = snapshot.fetch(:bytes)
        valid = bytes == snapshot_store.backup_bytes(entry) &&
          bytes.bytesize == entry.fetch("bytes") &&
          Digest::SHA256.hexdigest(bytes) == entry.fetch("digest") &&
          snapshot.fetch(:mode) == entry.fetch("mode") &&
          snapshot.fetch(:mtime) == Time.iso8601(entry.fetch("mtime"))
        inconsistent!("#{label} does not match the selected snapshot") unless
          valid
      end

      def quarantine_candidate!(_snapshot_id)
        expected = quarantine_path(candidate_transaction_id)
        if @candidate_root == expected
          return expected
        end
        unless @candidate_root == @target_root
          inconsistent!("selected v3 JobStore generation is not quarantinable")
        end
        transition_directory.quarantine_child!(
          live_name: File.basename(@target_root),
          quarantine_directory: QUARANTINE_ROOT,
          quarantine_name: candidate_transaction_id
        )
      end

      def restore_stage_name(transaction_id)
        ".job-schema-v2-restore-#{transaction_id}"
      end

      def quarantine_path(transaction_id)
        File.join(
          File.dirname(@target_root), QUARANTINE_ROOT, transaction_id
        )
      end

      def candidate_job_inventory
        Hive::Modules::Migration::BoundedFileInventory.new(
          directory: directory,
          relative: "jobs",
          filename_pattern:
            JobStoreSchemaMigration::INVENTORY_NAME_PATTERN,
          max_entries: MAX_JOB_FILES,
          cursor_prefix: "refactor-job-restore",
          malformed_message:
            "refactor patrol restore inventory is malformed",
          overflow_message:
            "refactor patrol restore inventory is too large",
          missing: false
        )
      end

      def inventory_names(inventory)
        snapshot = inventory.snapshot
        names = inventory.each_name(
          page_size: 256, snapshot: snapshot
        ).to_a
        JobStoreSchemaMigration.validate_job_inventory_names!(names)
      end

      def snapshot_store
        @snapshot_store ||= JobSchemaSnapshot.new(
          directory: directory,
          project_id: @project_id,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def transformer
        @transformer ||= LegacyJobTransformer.new(
          target_version: @target_version,
          validator: @validator,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def conversion_proof
        @conversion_proof ||= JobSchemaConversionProof.new(
          transformer: transformer,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def directory
        @directory ||= Hive::ManagedDirectory.new(
          root: @candidate_root,
          anchor: @anchor,
          label: "refactor patrol schema restore candidate"
        )
      end

      def legacy_directory
        @legacy_directory ||= Hive::ManagedDirectory.new(
          root: @legacy_root,
          anchor: @anchor,
          label: "released refactor patrol JobStore namespace"
        )
      end

      def transition_directory
        @transition_directory ||= Hive::ManagedDirectory.new(
          root: File.dirname(@target_root),
          anchor: @anchor,
          label: "refactor patrol schema restore transition"
        )
      end

      def tombstone
        @tombstone ||= JobSchemaTombstone.new(
          directory: legacy_directory,
          project_id: @project_id,
          target_version: @target_version,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def parse_object(bytes, relative)
        data = JSON.parse(bytes)
        corrupt!("JobStore record must be an object", relative) unless
          data.is_a?(Hash)
        data
      rescue JSON::ParserError, EncodingError => error
        corrupt!(
          "JobStore record is malformed " \
          "(#{error.class}: #{error.message})",
          relative
        )
      end

      def validate_filename!(name, data)
        return if data["job_id"] == name.delete_suffix(".json")

        inconsistent!(
          "JobStore job id does not match its filename",
          File.join("jobs", name)
        )
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def corrupt!(message, relative = nil)
        path =
          if relative&.start_with?(File::SEPARATOR)
            relative
          elsif relative
            File.join(@candidate_root || @target_root, relative)
          else
            @candidate_root || @target_root
          end
        raise @corrupt_record.new(message, path: path)
      end

      def inconsistent!(message, relative = nil)
        path =
          if relative&.start_with?(File::SEPARATOR)
            relative
          elsif relative
            File.join(@candidate_root || @target_root, relative)
          else
            @candidate_root || @target_root
          end
        raise @inconsistent_record.new(message, path: path)
      end
    end
  end
end
