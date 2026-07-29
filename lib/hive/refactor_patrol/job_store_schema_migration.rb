require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/modules/migration/occurrence_journal"
require "hive/modules/migration/patrol_evidence"
require "hive/refactor_patrol/decision_projection"
require "hive/refactor_patrol/job_schema_conversion_proof"
require "hive/refactor_patrol/job_schema_snapshot"
require "hive/refactor_patrol/job_schema_transition_lock"
require "hive/refactor_patrol/job_query_index"
require "hive/refactor_patrol/legacy_job_transformer"
require "hive/refactor_patrol/migration_writer_fence"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Mandatory, restart-safe one-off conversion of the released aggregate-only
    # JobStore v2 format. Every converted v3 aggregate is its own progress
    # checkpoint; normal readers never understand v2.
    class JobStoreSchemaMigration
      MARKER_SCHEMA =
        "hive-refactor-patrol-job-schema-migration".freeze
      MARKER_VERSION = 2
      SOURCE_VERSION = 2
      LOCK_NAME = "job-schema-v3-migration.lock".freeze
      MARKER_NAME = "job-schema-v3-migration.json".freeze
      JOB_ID_SOURCE = "[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}".freeze
      JOB_ENTRY_PATTERN =
        /\A#{JOB_ID_SOURCE}\.json(?:\.lock)?\z/
      MAX_JOB_ENTRIES = 8_192
      MAX_JOB_BYTES = 8 * 1024 * 1024
      MAX_MARKER_BYTES = 32 * 1024
      MAX_CONVERSION_BYTES = JobSchemaConversionProof::MAX_BYTES
      CONVERSION_ROOT = JobSchemaConversionProof::ROOT
      MARKER_KEYS = %w[
        migrated_jobs schema schema_version snapshot_id
        source_schema_version status target_schema_version
      ].freeze
      TERMINAL_EFFECT_STATES = %w[
        denied known_not_sent unknown committed reconciled failed
      ].freeze

      attr_reader :snapshot_id

      def initialize(root:, target_version:, validator:,
                     corrupt_record:, inconsistent_record:,
                     project:, ownership: nil, anchor: nil, directory: nil,
                     writer_fence: MigrationWriterFence.new,
                     clock: -> { Time.now.utc })
        @root = File.expand_path(root)
        @target_version = Integer(target_version)
        @validator = validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @project = normalized_project(project)
        @ownership = normalized_ownership(ownership)
        @anchor = File.expand_path(anchor || File.dirname(@root))
        @directory = directory
        @writer_fence = writer_fence
        @clock = clock
      end

      def run!(transition_lock: true)
        return false unless root_present?

        operation = lambda do
          directory.prepare!
          directory.with_lock(LOCK_NAME) do
            if (marker = completed_marker)
              @snapshot_id = marker.fetch("snapshot_id")
              assert_no_source_records!
              next false
            end

            inventory = capture_inventory
            legacy = inventory.select do |entry|
              entry.fetch(:version) == SOURCE_VERSION
            end
            snapshot = snapshot_store
            existing_snapshot = snapshot.manifest
            next false if legacy.empty? && !existing_snapshot

            @writer_fence.assert_quiescent!
            assert_migration_paths_available! unless existing_snapshot
            manifest = snapshot.prepare!(
              legacy,
              current_names:
                inventory.map { |entry| entry.fetch(:name) }
            )
            @snapshot_id = manifest.fetch("snapshot_id")
            assert_conversion_name_subset!(manifest)
            migrated = migrate_inventory!(inventory, manifest)
            @writer_fence.assert_quiescent!
            completed = assert_completed_inventory!(snapshot)
            rebuild_query_index!(completed)
            write_marker(snapshot, migrated)
            true
          end
        end
        if transition_lock
          JobSchemaTransitionLock.with_lock(@root, &operation)
        else
          operation.call
        end
      rescue @corrupt_record, @inconsistent_record,
             Hive::ConcurrentRunError
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "refactor patrol job migration storage is unsafe " \
          "(#{error.class}: #{error.message})",
          path: @root
        )
      end

      # Read-only, bounded probe used by list/show and installation status.
      def status
        return {
          "status" => "absent",
          "source_schema_version" => SOURCE_VERSION,
          "target_schema_version" => @target_version,
          "snapshot_id" => nil
        } unless root_present?

        directory.prepare!
        marker = completed_marker
        snapshot = snapshot_store.manifest
        versions = capture_inventory(
          lock_jobs: false, include_metadata: false
        ).map { |entry| entry.fetch(:version) }
        if versions.include?(SOURCE_VERSION)
          state = "migration_required"
        elsif snapshot && !marker &&
              versions.all? { |version| version == @target_version }
          state = "migration_required"
        elsif versions.all? { |version| version == @target_version }
          state = "current"
        else
          state = "unsupported"
        end
        {
          "status" => state,
          "source_schema_version" => SOURCE_VERSION,
          "target_schema_version" => @target_version,
          "snapshot_id" =>
            marker&.fetch("snapshot_id") ||
              snapshot&.fetch("snapshot_id")
        }
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "cannot inspect refactor patrol job schema " \
          "(#{error.class}: #{error.message})",
          path: @root
        )
      end

      def snapshot_identity
        return nil unless root_present?

        directory.prepare!
        snapshot_store.manifest&.fetch("snapshot_id")
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        raise @corrupt_record.new(
          "cannot inspect refactor patrol schema snapshot " \
          "(#{error.class}: #{error.message})",
          path: @root
        )
      end

      private

      def capture_inventory(lock_jobs: true, include_metadata: true)
        names = inventory_names(job_inventory)
        names.filter_map do |name|
          next unless name.end_with?(".json")

          read_entry = lambda do
            relative = relative_path("jobs", name)
            snapshot = directory.read_with_metadata(
              relative, max_bytes: MAX_JOB_BYTES
            )
            bytes = snapshot.fetch(:bytes)
            data = parse_job_bytes(bytes, relative)
            validate_filename!(name, data)
            version = data.fetch("schema_version")
            unless [ SOURCE_VERSION, @target_version ].include?(version)
              corrupt!(
                "unsupported refactor patrol job schema_version " \
                "#{version.inspect}",
                relative_path("jobs", name)
              )
            end
            @validator.validate_job!(
              data, path: absolute_path("jobs", name)
            ) if version == @target_version
            entry = {
              name: name,
              data: data,
              bytes: bytes,
              digest: Digest::SHA256.hexdigest(bytes),
              version: version
            }
            if include_metadata
              entry[:mode] = snapshot.fetch(:mode)
              entry[:mtime] = snapshot.fetch(:mtime).iso8601(9)
            end
            entry.freeze
          end
          if lock_jobs
            directory.with_lock(
              relative_path("jobs", "#{name}.lock")
            ) { read_entry.call }
          else
            read_entry.call
          end
        end.freeze
      rescue KeyError => error
        corrupt!(
          "refactor patrol job migration is missing #{error.key.inspect}"
        )
      end

      def migrate_inventory!(inventory, manifest)
        snapshot_entries = manifest.fetch("entries").to_h do |entry|
          [ entry.fetch("name"), entry ]
        end
        migrated = 0
        inventory.each do |entry|
          name = entry.fetch(:name)
          directory.with_lock(relative_path("jobs", "#{name}.lock")) do
            data, bytes = read_job_with_bytes(name)
            validate_filename!(name, data)
            version = data.fetch("schema_version")
            if version == @target_version
              @validator.validate_job!(
                data, path: absolute_path("jobs", name)
              )
              validate_v3_checkpoint!(
                entry.merge(
                  data: data,
                  bytes: bytes,
                  digest: Digest::SHA256.hexdigest(bytes),
                  version: version
                ),
                snapshot_entries.fetch(name) do
                  inconsistent!(
                    "live JobStore does not have the snapshot's exact job " \
                    "name set",
                    relative_path("jobs", name)
                  )
                end
              )
              next
            end
            unless version == SOURCE_VERSION
              corrupt!(
                "unsupported refactor patrol job schema_version " \
                "#{version.inspect}",
                relative_path("jobs", name)
              )
            end
            unless Digest::SHA256.hexdigest(bytes) ==
                   entry.fetch(:digest)
              inconsistent!(
                "refactor patrol job changed during schema migration",
                relative_path("jobs", name)
              )
            end
            assert_no_live_child_writer!(data, name)
            migrate_record!(name, data, entry.fetch(:digest))
            migrated += 1
          end
        end
        migrated
      end

      def assert_migration_paths_available!
        %w[
          occurrences
          job-schema-v3-conversions
          indexes/job-query
        ].each do |relative|
          next unless directory.directory_metadata(
            relative, missing: true
          )

          inconsistent!(
            "refactor patrol migration-only path predates the v2 snapshot",
            relative
          )
        end
        marker = directory.read(
          MARKER_NAME, max_bytes: MAX_MARKER_BYTES, missing: true
        )
        inconsistent!(
          "refactor patrol migration marker predates the v2 snapshot",
          MARKER_NAME
        ) if marker
      end

      def migrate_record!(name, data, source_digest)
        capture = migration_capture(data, source_digest)
        journal.reserve!(capture, now: occurred_at(data))
        intent = migration_intent(capture, data)
        receipt = settle_intake!(intent, now: occurred_at(data))
        replacement = transformer.transform(
          data,
          occurrence_id: capture.occurrence_id,
          intake_transition_id: intent.intent_id,
          path: absolute_path("jobs", name)
        )
        write_conversion_record!(
          name, replacement, source_digest,
          occurrence_id: capture.occurrence_id,
          intake_transition_id: intent.intent_id
        )
        write_job(
          name, replacement, expected_digest: source_digest
        )
        finalize_completed_import!(
          replacement, capture, receipt,
          now: occurred_at(data)
        ) if replacement.fetch("complete")
        replacement
      end

      def migration_capture(data, source_digest)
        job_id = data.fetch("job_id")
        timestamp = occurred_at(data)
        selection_input =
          Hive::RefactorPatrol::DecisionProjection.operation_input(
            job_id: job_id,
            phase: "discovery",
            operation: "schema_v2_import"
          )
        Hive::Modules::Migration::PatrolCapture.build(
          module_name: "architecture-patrol",
          project: {
            "project_id" => @project.fetch("project_id"),
            "name" => data.dig("source", "registration") ||
              @project.fetch("name"),
            "repository" => data.dig("source", "repository")
          },
          trigger: {
            "kind" => "job_store.schema_v2_import",
            "id" => [
              @project.fetch("project_id"), job_id, source_digest
            ].join(":"),
            "source_schema_version" => SOURCE_VERSION,
            "source_digest" => source_digest
          },
          reservation: {
            "kind" => "architecture",
            "id" => job_id,
            "job_id" => job_id,
            "window_started_at" => timestamp.iso8601(6),
            "attempt_generation" => 1
          },
          owner: @ownership.fetch("owner"),
          owner_epoch: @ownership.fetch("epoch"),
          selection_input: selection_input,
          selection:
            Hive::RefactorPatrol::DecisionProjection.project(
              selection_input
            ),
          outcome_class: nil,
          outcome: nil,
          occurred_at: timestamp,
          recorded_at: timestamp
        )
      rescue Hive::ConfigError, KeyError => error
        corrupt!(
          "cannot build migration occurrence " \
          "(#{error.class}: #{error.message})"
        )
      end

      def migration_intent(capture, data)
        job_id = data.fetch("job_id")
        Hive::Modules::Migration::EffectIntent.build(
          module_name: "architecture-patrol",
          occurrence_id: capture.occurrence_id,
          authority: @ownership.fetch("owner"),
          owner_epoch: @ownership.fetch("epoch"),
          sink: "job",
          target: "#{job_id}:schema-v2-import",
          idempotency_key: "schema-v2-import:#{job_id}",
          capability: "filesystem_write",
          created_at: occurred_at(data),
          scope: {
            "job_id" => job_id,
            "operation" => "schema_v2_import"
          }
        )
      rescue Hive::ConfigError, KeyError => error
        corrupt!(
          "cannot build migration intake transition " \
          "(#{error.class}: #{error.message})"
        )
      end

      def settle_intake!(intent, now:)
        cell = journal.effect_state(intent)
        unless cell
          journal.prepare_effect!(intent, now: now)
          cell = journal.effect_state(intent)
        end
        if cell.fetch("state") == "prepared"
          journal.mark_dispatch_uncertain!(intent, now: now)
          cell = journal.effect_state(intent)
        end
        outcome = {
          "transition_status" => "applied",
          "migration" => "schema_v2_import"
        }
        if cell.fetch("state") == "dispatch_uncertain" ||
           TERMINAL_EFFECT_STATES.include?(cell.fetch("state"))
          return journal.settle_effect!(
            intent, status: "committed", outcome: outcome, now: now
          )
        end
        corrupt!(
          "migration intake transition is not recoverable"
        )
      rescue Hive::ConfigError, KeyError => error
        corrupt!(
          "cannot persist migration intake transition " \
          "(#{error.class}: #{error.message})"
        )
      end

      def finalize_completed_import!(job, provisional, receipt, now:)
        final = Hive::Modules::Migration::PatrolCapture.build(
          module_name: provisional.module_name,
          project: provisional.project,
          trigger: provisional.trigger,
          reservation: provisional.reservation,
          owner: provisional.owner,
          owner_epoch: provisional.owner_epoch,
          selection_input: provisional.selection_input,
          selection: provisional.selection,
          outcome_class: "schema_v2_import",
          outcome: {
            "job_id" => job.fetch("job_id"),
            "state" => job.fetch("state"),
            "complete" => true
          },
          effect_ids: [ receipt.receipt_id ],
          occurred_at: provisional.occurred_at,
          recorded_at: now
        )
        journal.finalize!(final, now: now)
        journal.pending_outbox(final.occurrence_id).each do |entry|
          journal.acknowledge_outbox!(
            final.occurrence_id,
            entry_id: entry.fetch("id"),
            digest: entry.fetch("digest")
          )
        end
      rescue Hive::ConfigError, KeyError => error
        corrupt!(
          "cannot finalize completed migration occurrence " \
          "(#{error.class}: #{error.message})"
        )
      end

      def assert_no_live_child_writer!(data, name)
        writer_identities(data).each do |identity|
          pid = identity.fetch("pid")
          recorded = identity.fetch("process_start_time")
          next unless pid.is_a?(Integer) && pid > 1
          next unless Hive::PidFile.alive?(pid)

          live = Hive::Lock.process_start_time(pid)
          next unless live && recorded && live.to_s == recorded.to_s

          raise Hive::ConcurrentRunError.new(
            "live refactor patrol worker must stop before JobStore migration",
            holder: identity,
            lock_path: absolute_path("jobs", "#{name}.lock")
          )
        end
      end

      def writer_identities(data)
        attempts = Array(data["attempts"])
        claims = Array(data["actions"]).flat_map do |action|
          action.is_a?(Hash) ? Array(action["claims"]) : []
        end
        (attempts + claims).filter_map do |entry|
          next unless entry.is_a?(Hash)
          next unless %w[claimed running].include?(entry["state"])

          pid = entry["pid"] || entry["owner_pid"]
          process_start_time =
            entry["process_start_time"] ||
            entry["owner_process_start_time"]
          {
            "pid" => pid,
            "process_start_time" => process_start_time
          }
        end
      end

      def completed_marker
        bytes = directory.read(
          MARKER_NAME, max_bytes: MAX_MARKER_BYTES, missing: true
        )
        return nil unless bytes

        data = JSON.parse(bytes)
        valid = bytes ==
                  Hive::WorkflowPackage::CanonicalJSON.generate(data) &&
                data.is_a?(Hash) &&
                data.keys.sort == MARKER_KEYS &&
                data["schema"] == MARKER_SCHEMA &&
                data["schema_version"] == MARKER_VERSION &&
                data["source_schema_version"] == SOURCE_VERSION &&
                data["target_schema_version"] == @target_version &&
                data["status"] == "complete" &&
                data["migrated_jobs"].is_a?(Integer) &&
                data["migrated_jobs"].between?(1, MAX_JOB_ENTRIES) &&
                data["snapshot_id"].to_s
                    .match?(/\Asnapshot-[0-9a-f]{64}\z/)
        corrupt!(
          "refactor patrol job migration marker is malformed",
          MARKER_NAME
        ) unless valid
        snapshot = snapshot_store.manifest
        inconsistent!(
          "refactor patrol job migration snapshot is missing",
          MARKER_NAME
        ) unless snapshot
        inconsistent!(
          "refactor patrol job migration marker snapshot identity conflicts",
          MARKER_NAME
        ) unless snapshot.fetch("snapshot_id") ==
                 data.fetch("snapshot_id")
        inconsistent!(
          "refactor patrol job migration marker job count conflicts",
          MARKER_NAME
        ) unless snapshot.fetch("entries").size ==
                 data.fetch("migrated_jobs")
        data
      rescue JSON::ParserError, EncodingError, ArgumentError => error
        corrupt!(
          "refactor patrol job migration marker is malformed " \
          "(#{error.message})",
          MARKER_NAME
        )
      end

      def write_marker(snapshot, migrated)
        total = snapshot.manifest.fetch("entries").size
        inconsistent!(
          "refactor patrol job migration made no progress"
        ) if migrated.zero? && total.zero?
        payload = {
          "schema" => MARKER_SCHEMA,
          "schema_version" => MARKER_VERSION,
          "source_schema_version" => SOURCE_VERSION,
          "target_schema_version" => @target_version,
          "migrated_jobs" => total,
          "snapshot_id" => snapshot.snapshot_id,
          "status" => "complete"
        }
        directory.atomic_write(
          MARKER_NAME,
          Hive::WorkflowPackage::CanonicalJSON.generate(payload),
          mode: 0o600
        )
      end

      def assert_no_source_records!
        capture_inventory.each do |entry|
          next unless entry.fetch(:version) == SOURCE_VERSION

          inconsistent!(
            "released refactor patrol v2 job remains after schema migration",
            relative_path("jobs", entry.fetch(:name))
          )
        end
      end

      def assert_completed_inventory!(snapshot)
        inventory = capture_inventory
        legacy = inventory.select do |entry|
          entry.fetch(:version) == SOURCE_VERSION
        end
        manifest = snapshot.prepare!(
          legacy,
          current_names: inventory.map { |entry| entry.fetch(:name) }
        )
        snapshot_entries = manifest.fetch("entries").to_h do |entry|
          [ entry.fetch("name"), entry ]
        end
        unless conversion_record_names == snapshot_entries.keys.sort
          inconsistent!(
            "conversion ledger does not have the snapshot's exact job name set",
            CONVERSION_ROOT
          )
        end
        inventory.each do |entry|
          if entry.fetch(:version) == SOURCE_VERSION
            inconsistent!(
              "released refactor patrol v2 job remains after schema migration",
              relative_path("jobs", entry.fetch(:name))
            )
          end
          validate_v3_checkpoint!(
            entry, snapshot_entries.fetch(entry.fetch(:name))
          )
        end
        inventory
      end

      def assert_conversion_name_subset!(manifest)
        expected = manifest.fetch("entries").map do |entry|
          entry.fetch("name")
        end
        unknown = conversion_record_names - expected
        return if unknown.empty?

        inconsistent!(
          "conversion ledger contains a job outside the snapshot",
          relative_path(CONVERSION_ROOT, unknown.first)
        )
      end

      def conversion_record_names
        names = directory.each_child(
          CONVERSION_ROOT, missing: true
        ).to_a.sort
        if names.size > MAX_JOB_ENTRIES ||
           names.any? { |name| !name.match?(
             /\A#{JOB_ID_SOURCE}\.json\z/
           ) }
          corrupt!(
            "refactor patrol conversion ledger inventory is malformed",
            CONVERSION_ROOT
          )
        end
        names
      end

      def rebuild_query_index!(inventory)
        ordered = inventory.sort_by do |entry|
          data = entry.fetch(:data)
          [
            Time.iso8601(data.fetch("created_at")).utc,
            data.fetch("job_id")
          ]
        end.map { |entry| entry.fetch(:data).fetch("job_id") }
        query_index.rebuild! { ordered }
      rescue ArgumentError, KeyError => error
        inconsistent!(
          "cannot build the v3 job query index before schema admission " \
          "(#{error.class}: #{error.message})",
          "indexes/job-query"
        )
      end

      def validate_filename!(name, data)
        expected = name.delete_suffix(".json")
        return if data["job_id"] == expected

        inconsistent!(
          "refactor patrol job id does not match its filename",
          relative_path("jobs", name)
        )
      end

      def write_job(name, data, expected_digest:)
        directory.atomic_write(
          relative_path("jobs", name),
          "#{JSON.pretty_generate(data)}\n",
          mode: 0o600,
          expected_digest: expected_digest,
          max_existing_bytes: MAX_JOB_BYTES
        )
      end

      def write_conversion_record!(name, replacement, source_digest,
                                   occurrence_id:, intake_transition_id:)
        target_bytes = "#{JSON.pretty_generate(replacement)}\n"
        payload = JobSchemaConversionProof.build(
          snapshot_id: @snapshot_id,
          name: name,
          job_id: replacement.fetch("job_id"),
          source_digest: source_digest,
          target_bytes: target_bytes,
          occurrence_id: occurrence_id,
          intake_transition_id: intake_transition_id
        )
        bytes = Hive::WorkflowPackage::CanonicalJSON.generate(payload)
        existing = directory.read(
          relative_path(CONVERSION_ROOT, name),
          max_bytes: MAX_CONVERSION_BYTES,
          missing: true
        )
        if existing
          inconsistent!(
            "refactor patrol conversion proof conflicts",
            relative_path(CONVERSION_ROOT, name)
          ) unless existing == bytes
          return
        end
        directory.atomic_write(
          relative_path(CONVERSION_ROOT, name),
          bytes,
          mode: 0o600
        )
      end

      def read_job_with_bytes(name)
        relative = relative_path("jobs", name)
        bytes = directory.read(relative, max_bytes: MAX_JOB_BYTES)
        [ parse_job_bytes(bytes, relative), bytes ]
      end

      def validate_v3_checkpoint!(live, snapshot_entry)
        name = live.fetch(:name)
        source_bytes = snapshot_store.backup_bytes(snapshot_entry)
        source_data = parse_job_bytes(
          source_bytes,
          relative_path(
            JobSchemaSnapshot::ROOT, "jobs", name
          )
        )
        validate_filename!(name, source_data)
        proof_path = relative_path(CONVERSION_ROOT, name)
        proof_bytes = directory.read(
          proof_path, max_bytes: MAX_CONVERSION_BYTES
        )
        conversion_proof.verify!(
          proof_bytes: proof_bytes,
          name: name,
          snapshot_id: @snapshot_id,
          source_digest: snapshot_entry.fetch("digest"),
          source_data: source_data,
          live_bytes: live.fetch(:bytes),
          path: absolute_path(proof_path)
        )
      end

      def parse_job_bytes(bytes, relative)
        data = JSON.parse(bytes)
        corrupt!(
          "refactor patrol migration input must be an object",
          relative
        ) unless data.is_a?(Hash)
        data
      rescue JSON::ParserError, EncodingError, ArgumentError => error
        corrupt!(
          "cannot read refactor patrol migration input " \
          "(#{error.class}: #{error.message})",
          relative
        )
      end

      def inventory_names(inventory)
        snapshot = inventory.snapshot
        inventory.each_name(
          page_size: 256, snapshot: snapshot
        ).to_a
      end

      def job_inventory
        Hive::Modules::Migration::BoundedFileInventory.new(
          directory: directory,
          relative: "jobs",
          filename_pattern: JOB_ENTRY_PATTERN,
          max_entries: MAX_JOB_ENTRIES,
          cursor_prefix: "refactor-job-migration",
          malformed_message:
            "refactor patrol job migration inventory is malformed",
          overflow_message:
            "refactor patrol job migration inventory is too large",
          missing: true
        )
      end

      def snapshot_store
        @snapshot_store ||= Hive::RefactorPatrol::JobSchemaSnapshot.new(
          directory: directory,
          project_id: @project.fetch("project_id"),
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record,
          clock: @clock
        )
      end

      def conversion_proof
        @conversion_proof ||= JobSchemaConversionProof.new(
          transformer: transformer,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def query_index
        @query_index ||= JobQueryIndex.new(
          root: @root,
          id_pattern: /\A#{JOB_ID_SOURCE}\z/,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def transformer
        @transformer ||= Hive::RefactorPatrol::LegacyJobTransformer.new(
          target_version: @target_version,
          validator: @validator,
          corrupt_record: @corrupt_record,
          inconsistent_record: @inconsistent_record
        )
      end

      def journal
        @journal ||= Hive::Modules::Migration::OccurrenceJournal.new(
          File.join(@root, "occurrences", "records"),
          module_name: "architecture-patrol"
        )
      end

      def occurred_at(data)
        value = data.dig("source", "merged_at") || data.fetch("created_at")
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc
      rescue ArgumentError, TypeError, KeyError => error
        corrupt!(
          "refactor patrol migration occurrence time is malformed " \
          "(#{error.message})"
        )
      end

      def normalized_project(value)
        data = value.is_a?(Hash) ? value : {}
        name = data["name"] || data[:name] || "unregistered"
        project_id = data["project_id"] || data[:project_id]
        project_id = "local-#{Digest::SHA256.hexdigest(@root)}" if
          project_id.to_s.empty?
        {
          "name" => name.to_s,
          "project_id" => project_id.to_s
        }.freeze
      end

      def normalized_ownership(value)
        data = value.is_a?(Hash) ? value : {}
        owner = (data["owner"] || data[:owner] || "legacy").to_s
        epoch = data["epoch"] || data[:epoch] || 1
        unless %w[legacy module].include?(owner) &&
               Integer(epoch).positive?
          raise ArgumentError, "migration ownership is malformed"
        end
        {
          "owner" => owner,
          "epoch" => Integer(epoch)
        }.freeze
      end

      def directory
        @directory ||= Hive::ManagedDirectory.new(
          root: @root,
          anchor: @anchor,
          label: "refactor patrol job schema migration"
        )
      end

      def root_present?
        File.lstat(@root)
        true
      rescue Errno::ENOENT
        false
      end

      def relative_path(*parts)
        File.join(*parts)
      end

      def absolute_path(*parts)
        File.join(@root, *parts)
      end

      def corrupt!(message, relative = nil)
        path = relative && absolute_path(relative)
        raise @corrupt_record.new(message, path: path)
      end

      def inconsistent!(message, relative = nil)
        path = relative && absolute_path(relative)
        raise @inconsistent_record.new(message, path: path)
      end
    end
  end
end
