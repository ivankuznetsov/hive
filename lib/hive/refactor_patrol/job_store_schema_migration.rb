require "digest"
require "json"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/modules/migration/occurrence_record_validator"
require "hive/refactor_patrol/transition_evidence"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Fenced, restartable one-off conversion from the former v2 job shape and
    # sidecar occurrence binding to the JobStore-owned v3 authority model.
    # Runtime readers never understand v2; initialization completes this
    # conversion before a JobStore can expose records.
    class JobStoreSchemaMigration
      MARKER_SCHEMA =
        "hive-refactor-patrol-job-schema-migration".freeze
      MARKER_VERSION = 1
      SOURCE_VERSION = 2
      LOCK_NAME = "job-schema-v3-migration.lock".freeze
      MARKER_NAME = "job-schema-v3-migration.json".freeze
      JOB_ID_SOURCE = "[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}".freeze
      JOB_ENTRY_PATTERN =
        /\A#{JOB_ID_SOURCE}\.json(?:\.lock)?\z/
      BINDING_ENTRY_PATTERN = JOB_ENTRY_PATTERN
      MAX_JOB_ENTRIES = 8_192
      MAX_BINDING_ENTRIES = 8_192
      MAX_JOB_BYTES = 8 * 1024 * 1024
      MAX_BINDING_BYTES = 16_384
      MAX_MARKER_BYTES = 16_384
      LOCAL_SINKS = %w[job discovery action].freeze
      APPLIED_STATES = %w[committed reconciled].freeze
      UNAPPLIED_TERMINAL_STATES = %w[denied failed].freeze
      MARKER_KEYS = %w[
        migrated_jobs schema schema_version source_schema_version status
        target_schema_version
      ].freeze

      def initialize(root:, target_version:, validator:,
                     corrupt_record:, inconsistent_record:)
        @root = File.expand_path(root)
        @target_version = target_version
        @validator = validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
      end

      def run!
        return false unless root_present?

        directory.prepare!
        return false if completed?
        return false unless legacy_state?

        directory.with_lock(LOCK_NAME) do
          next false if completed?

          migrate_locked!
        end
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError => e
        raise @corrupt_record,
              "refactor patrol job migration storage is unsafe " \
              "(#{e.message})"
      end

      private

      def legacy_state?
        return true if lock_present?
        return true unless binding_entry_names.empty?

        job_record_names.any? do |name|
          read_job(name).fetch("schema_version") == SOURCE_VERSION
        end
      rescue KeyError => e
        corrupt!(
          "refactor patrol job migration is missing #{e.key.inspect}"
        )
      end

      def migrate_locked!
        plan = preflight
        migrated = 0
        plan.fetch(:jobs).each do |name, expected|
          data, bytes = read_job_with_bytes(name)
          unless Digest::SHA256.hexdigest(bytes) ==
                 expected.fetch(:digest)
            inconsistent!(
              "refactor patrol job changed during schema migration",
              relative_path("jobs", name)
            )
          end

          if data.fetch("schema_version") == SOURCE_VERSION
            replacement = migrate_record(
              data,
              relative_path("jobs", name),
              plan.fetch(:bindings).fetch(data.fetch("job_id"))
            )
            @validator.validate_job!(
              replacement, path: absolute_path("jobs", name)
            )
            write_job(
              name,
              replacement,
              expected_digest: expected.fetch(:digest)
            )
            migrated += 1
          else
            @validator.validate_job!(
              data, path: absolute_path("jobs", name)
            )
          end
          remove_binding_artifacts!(
            data.fetch("job_id"),
            occurrence_id: expected.fetch(:occurrence_id)
          )
        end
        unless binding_entry_names.empty?
          inconsistent!(
            "legacy occurrence bindings remain after schema migration"
          )
        end

        write_marker(migrated)
        true
      rescue KeyError => e
        corrupt!(
          "refactor patrol job migration is missing #{e.key.inspect}"
        )
      end

      def preflight
        jobs = {}
        job_record_names.each do |name|
          data, bytes = read_job_with_bytes(name)
          path = absolute_path("jobs", name)
          expected_job_id = name.delete_suffix(".json")
          unless data["job_id"] == expected_job_id
            inconsistent!(
              "refactor patrol job id does not match its filename",
              relative_path("jobs", name)
            )
          end
          version = data["schema_version"]
          unless [ SOURCE_VERSION, @target_version ].include?(version)
            corrupt!(
              "unsupported refactor patrol job schema_version " \
              "#{version.inspect}",
              relative_path("jobs", name)
            )
          end
          @validator.validate_job!(data, path: path) if
            version == @target_version
          jobs[name] = {
            digest: Digest::SHA256.hexdigest(bytes),
            version: version,
            occurrence_id: data["occurrence_id"]
          }
        end

        job_ids = jobs.keys.to_h do |name|
          [ name.delete_suffix(".json"), true ]
        end
        binding_entry_names.each do |name|
          job_id = binding_job_id(name)
          next if job_ids.key?(job_id)

          inconsistent!(
            "legacy occurrence binding has no corresponding job",
            relative_path("occurrences", "jobs", name)
          )
        end
        bindings = binding_record_names.to_h do |name|
          binding = read_binding(name)
          [ binding.fetch("job_id"), binding ]
        end

        jobs.each do |name, metadata|
          data = read_job(name)
          job_id = data.fetch("job_id")
          binding = bindings[job_id]
          if metadata.fetch(:version) == SOURCE_VERSION
            unless binding
              inconsistent!(
                "legacy refactor patrol job has no occurrence binding",
                relative_path("jobs", name)
              )
            end
            replacement = migrate_record(
              data, relative_path("jobs", name), binding
            )
            @validator.validate_job!(
              replacement, path: absolute_path("jobs", name)
            )
            metadata[:occurrence_id] =
              replacement.fetch("occurrence_id")
          elsif binding
            unless binding.fetch("occurrence_id") ==
                   data.fetch("occurrence_id")
              inconsistent!(
                "legacy occurrence binding conflicts with migrated job",
                relative_path("jobs", name)
              )
            end
            metadata[:occurrence_id] =
              data.fetch("occurrence_id")
          end
        end
        { jobs: jobs.freeze, bindings: bindings.freeze }.freeze
      end

      def migrate_record(data, path, binding)
        if data.key?("occurrence_id") ||
           data.key?("intake_transition_id")
          inconsistent!(
            "legacy refactor patrol job mixes v2 and v3 authority fields",
            path
          )
        end

        job_id = data.fetch("job_id").to_s
        occurrence_id = binding.fetch("occurrence_id")
        occurrence = read_occurrence(occurrence_id)
        unless occurrence.dig(
          "provisional_capture", "reservation", "job_id"
        ) == job_id
          inconsistent!(
            "refactor patrol occurrence does not match migrated job",
            path
          )
        end

        cells = migratable_transition_cells(occurrence.fetch("effects"))
        intake = cells.select do |cell|
          cell.dig("semantic", "sink") == "job"
        end
        unless intake.one? &&
               intake.first.dig("semantic", "scope", "job_id") == job_id
          inconsistent!(
            "refactor patrol intake transition is ambiguous",
            path
          )
        end

        replacement = copy(data)
        replacement["schema_version"] = @target_version
        replacement["occurrence_id"] = occurrence_id
        replacement["intake_transition_id"] =
          intake.first.fetch("intent_id")
        replacement["attempts"] = migrate_attempts(
          replacement.fetch("attempts"),
          cells,
          occurrence_id,
          job_id
        )
        replacement["actions"] = migrate_actions(
          replacement.fetch("actions"), cells, occurrence_id
        )
        assert_all_transitions_assigned!(
          replacement, cells, intake.first.fetch("intent_id"), path
        )
        replacement
      rescue KeyError => e
        corrupt!(
          "refactor patrol job migration is missing #{e.key.inspect}",
          path
        )
      end

      def migrate_attempts(attempts, cells, occurrence_id, job_id)
        values = copy(attempts)
        diagnostic_cells = {
          "discovery_block" => cells.select do |cell|
            diagnostic_cell?(
              cell, sink: "discovery", job_id: job_id
            )
          end,
          "action_block" => cells.select do |cell|
            diagnostic_cell?(
              cell, sink: "action", job_id: job_id
            )
          end
        }
        diagnostic_offsets = diagnostic_cells.to_h do |kind, selected|
          count = values.count { |attempt| attempt["kind"] == kind }
          if selected.size > count
            inconsistent!(
              "refactor patrol diagnostic transition mapping is ambiguous"
            )
          end
          [ kind, count - selected.size ]
        end
        diagnostic_indexes = Hash.new(0)

        migrated = values.map do |attempt|
          kind = attempt["kind"]
          if kind == "discovery_claim"
            generation = attempt.fetch("generation")
            selected = transition_cells(
              cells, sink: "discovery", generation: generation
            ).reject do |cell|
              diagnostic_cell?(
                cell, sink: "discovery", job_id: job_id
              )
            end
            next attempt.merge(
              "occurrence_id" => occurrence_id,
              "transitions" => selected.map do |cell|
                transition_record(cell, generation)
              end
            )
          end

          unless diagnostic_cells.key?(kind)
            next attempt
          end

          diagnostic_indexes[kind] += 1
          generation = diagnostic_indexes.fetch(kind)
          selected_index =
            generation - diagnostic_offsets.fetch(kind) - 1
          cell = if selected_index >= 0
            diagnostic_cells.fetch(kind)[selected_index]
          end
          attempt.merge(
            "occurrence_id" => occurrence_id,
            "generation" => generation,
            "transitions" => cell ? [
              transition_record(cell, generation)
            ] : []
          )
        end

        job_transition_cells(cells, job_id).each do |cell|
          generation = claim_generation(cell)
          migrated << {
            "kind" => "job_transition",
            "operation" => operation(cell.fetch("semantic")),
            "occurrence_id" => occurrence_id,
            "generation" => generation,
            "transitions" => [
              transition_record(cell, generation)
            ],
            "recorded_at" => cell.fetch("updated_at")
          }
        end
        migrated
      end

      def migrate_actions(actions, cells, occurrence_id)
        copy(actions).map do |action|
          action_id = action.fetch("canonical_action_id")
          selected = transition_cells(
            cells, sink: "action", action_id: action_id
          )
          migrated = action.merge(
            "transitions" => selected.map do |cell|
              generation = claim_generation(cell)
              transition_record(cell, generation)
            end
          )
          if migrated.key?("claims")
            migrated["claims"] = migrated.fetch("claims").map do |claim|
              claim.merge("occurrence_id" => occurrence_id)
            end
          end
          migrated
        end
      end

      def migratable_transition_cells(effects)
        effects.values.filter_map do |cell|
          sink = cell.dig("semantic", "sink")
          next unless LOCAL_SINKS.include?(sink)

          state = cell.fetch("state")
          if APPLIED_STATES.include?(state)
            status = cell.dig("outcome", "transition_status")
            unless %w[applied rejected].include?(status)
              inconsistent!(
                "applied local transition has no exact transition outcome"
              )
            end
            cell
          elsif UNAPPLIED_TERMINAL_STATES.include?(state)
            if cell.dig("outcome", "transition_status")
              inconsistent!(
                "terminal unapplied transition carries a local outcome"
              )
            end
            nil
          else
            inconsistent!(
              "legacy local transition is not terminal; recover it before " \
              "schema migration"
            )
          end
        end
      end

      def transition_cells(cells, sink:, generation: nil,
                           action_id: nil)
        cells.select do |cell|
          semantic = cell.fetch("semantic")
          next false unless semantic.fetch("sink") == sink
          next false if generation &&
                        claim_generation(cell) != generation
          next false if action_id &&
                        semantic.dig(
                          "scope", "canonical_action_id"
                        ) != action_id

          true
        end.sort_by { |cell| cell.fetch("intent_id") }
      end

      def diagnostic_cell?(cell, sink:, job_id:)
        semantic = cell.fetch("semantic")
        semantic.fetch("sink") == sink &&
          semantic.fetch("target") == "#{job_id}:block" &&
          semantic.dig("scope", "job_id") == job_id &&
          semantic.dig("scope", "canonical_action_id").nil?
      end

      def job_transition_cells(cells, job_id)
        cells.select do |cell|
          semantic = cell.fetch("semantic")
          semantic.fetch("sink") == "action" &&
            semantic.dig("scope", "job_id") == job_id &&
            semantic.dig("scope", "canonical_action_id").nil? &&
            !diagnostic_cell?(
              cell, sink: "action", job_id: job_id
            )
        end.sort_by { |cell| cell.fetch("intent_id") }
      end

      def transition_record(cell, generation)
        semantic = cell.fetch("semantic")
        status = cell.dig("outcome", "transition_status")
        unless %w[applied rejected].include?(status)
          inconsistent!(
            "refactor patrol transition outcome is malformed"
          )
        end
        rejected = status == "rejected"
        error_code = rejected ?
          cell.dig("outcome", "error_code").to_s : nil
        if rejected && error_code.empty?
          inconsistent!(
            "refactor patrol rejected transition has no error code"
          )
        end
        record = {
          "intent_id" => cell.fetch("intent_id"),
          "operation" => operation(semantic),
          "generation" => generation,
          "semantic_digest" =>
            TransitionEvidence.semantic_digest(semantic),
          "outcome" => rejected ? "rejected" : "applied",
          "error_code" => error_code,
          "recorded_at" => cell.fetch("updated_at")
        }
        @validator.validate_transition_semantic!(
          record, semantic: semantic
        )
        record
      end

      def assert_all_transitions_assigned!(job, cells, intake_id, path)
        expected = cells.map { |cell| cell.fetch("intent_id") }.sort
        assigned = [ intake_id ]
        job.fetch("attempts").each do |attempt|
          assigned.concat(
            Array(attempt["transitions"]).map do |entry|
              entry.fetch("intent_id")
            end
          )
        end
        job.fetch("actions").each do |action|
          assigned.concat(
            action.fetch("transitions").map do |entry|
              entry.fetch("intent_id")
            end
          )
        end
        return if expected == assigned.sort &&
                  assigned.uniq.size == assigned.size

        inconsistent!(
          "refactor patrol transition cannot be assigned to its job owner",
          path
        )
      end

      def claim_generation(cell)
        generations = cell.fetch("authorizations").values.map do |value|
          value.fetch("claim_generation")
        end.uniq
        unless generations.one? &&
               generations.first.is_a?(Integer) &&
               generations.first.positive?
          inconsistent!(
            "refactor patrol transition generation is ambiguous"
          )
        end

        generations.first
      end

      def operation(semantic)
        value = semantic.fetch("target").to_s.split(":").last.to_s
        if value.empty?
          inconsistent!(
            "refactor patrol transition operation is malformed"
          )
        end
        semantic.fetch("sink") == "discovery" ?
          "discovery-#{value}" : value
      end

      def read_binding(name)
        path = relative_path("occurrences", "jobs", name)
        data, bytes = read_object(
          path, max_bytes: MAX_BINDING_BYTES, canonical: true
        )
        job_id = name.delete_suffix(".json")
        valid = data.keys.sort == %w[
          job_id occurrence_id schema schema_version
        ] &&
                data["schema"] ==
                  "hive-refactor-patrol-job-occurrence" &&
                data["schema_version"] == 1 &&
                data["job_id"] == job_id &&
                data["occurrence_id"].to_s
                    .match?(/\Aocc-[0-9a-f]{64}\z/)
        corrupt!(
          "architecture patrol occurrence binding is malformed",
          path
        ) unless valid

        data.merge(
          "__source_digest" => Digest::SHA256.hexdigest(bytes)
        )
      end

      def remove_binding_artifacts!(job_id, occurrence_id:)
        name = "#{job_id}.json"
        relative = relative_path("occurrences", "jobs", name)
        if directory.read(
          relative, max_bytes: MAX_BINDING_BYTES, missing: true
        )
          binding = read_binding(name)
          unless binding.fetch("occurrence_id") == occurrence_id
            inconsistent!(
              "legacy occurrence binding conflicts with migrated job",
              relative
            )
          end
          directory.unlink(
            relative,
            expected_digest: binding.fetch("__source_digest"),
            max_bytes: MAX_BINDING_BYTES
          )
        end
        directory.unlink(
          "#{relative}.lock", missing: true
        )
      end

      def read_occurrence(occurrence_id)
        name = "#{occurrence_id}.json"
        path = relative_path("occurrences", "records", name)
        data, = read_object(
          path,
          max_bytes:
            Hive::Modules::Migration::OccurrenceContract::MAX_RECORD_BYTES,
          canonical: true
        )
        occurrence_validator.validate!(
          data, expected_id: occurrence_id
        )
        data
      rescue Hive::ConfigError => e
        corrupt!(
          "refactor patrol occurrence is malformed (#{e.message})",
          path
        )
      end

      def occurrence_validator
        @occurrence_validator ||=
          Hive::Modules::Migration::OccurrenceRecordValidator.new(
            module_name: "architecture-patrol"
          )
      end

      def completed?
        bytes = directory.read(
          MARKER_NAME, max_bytes: MAX_MARKER_BYTES, missing: true
        )
        return false unless bytes

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
                data["migrated_jobs"].between?(0, MAX_JOB_ENTRIES)
        corrupt!(
          "refactor patrol job migration marker is malformed",
          MARKER_NAME
        ) unless valid

        assert_completed_state!
        true
      rescue JSON::ParserError, EncodingError, ArgumentError => e
        corrupt!(
          "refactor patrol job migration marker is malformed " \
          "(#{e.message})",
          MARKER_NAME
        )
      end

      def assert_completed_state!
        unless binding_entry_names.empty?
          inconsistent!(
            "legacy occurrence binding was reintroduced after schema migration"
          )
        end
      end

      def write_marker(migrated)
        payload = {
          "schema" => MARKER_SCHEMA,
          "schema_version" => MARKER_VERSION,
          "source_schema_version" => SOURCE_VERSION,
          "target_schema_version" => @target_version,
          "migrated_jobs" => migrated,
          "status" => "complete"
        }
        directory.atomic_write(
          MARKER_NAME,
          Hive::WorkflowPackage::CanonicalJSON.generate(payload),
          mode: 0o600
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

      def read_job(name)
        read_job_with_bytes(name).first
      end

      def read_job_with_bytes(name)
        read_object(
          relative_path("jobs", name), max_bytes: MAX_JOB_BYTES
        )
      end

      def read_object(relative, max_bytes:, canonical: false)
        bytes = directory.read(relative, max_bytes: max_bytes)
        data = JSON.parse(bytes)
        unless data.is_a?(Hash)
          corrupt!(
            "refactor patrol migration input must be an object",
            relative
          )
        end
        if canonical &&
           bytes != Hive::WorkflowPackage::CanonicalJSON.generate(data)
          corrupt!(
            "refactor patrol migration input is not canonical",
            relative
          )
        end
        [ data, bytes ]
      rescue JSON::ParserError, EncodingError, ArgumentError => e
        corrupt!(
          "cannot read refactor patrol migration input " \
          "(#{e.class}: #{e.message})",
          relative
        )
      end

      def copy(value)
        JSON.parse(JSON.generate(value))
      end

      def job_entry_names
        inventory_names(job_inventory)
      end

      def job_record_names
        job_entry_names.select { |name| name.end_with?(".json") }
      end

      def binding_entry_names
        inventory_names(binding_inventory)
      end

      def binding_record_names
        binding_entry_names.select { |name| name.end_with?(".json") }
      end

      def inventory_names(inventory)
        snapshot = inventory.snapshot
        inventory.each_name(
          page_size: 256, snapshot: snapshot
        ).to_a
      end

      def job_inventory
        @job_inventory ||=
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

      def binding_inventory
        @binding_inventory ||=
          Hive::Modules::Migration::BoundedFileInventory.new(
            directory: directory,
            relative: relative_path("occurrences", "jobs"),
            filename_pattern: BINDING_ENTRY_PATTERN,
            max_entries: MAX_BINDING_ENTRIES,
            cursor_prefix: "refactor-binding-migration",
            malformed_message:
              "refactor patrol binding migration inventory is malformed",
            overflow_message:
              "refactor patrol binding migration inventory is too large",
            missing: true
          )
      end

      def binding_job_id(name)
        name.delete_suffix(".lock").delete_suffix(".json")
      end

      def lock_present?
        bytes = directory.read(
          LOCK_NAME, max_bytes: 1, missing: true
        )
        return false if bytes.nil?

        corrupt!(
          "refactor patrol job migration lock is malformed",
          LOCK_NAME
        ) unless bytes.empty?
        true
      end

      def directory
        @directory ||= Hive::ManagedDirectory.new(
          root: @root,
          anchor: project_root,
          label: "refactor patrol job schema migration"
        )
      end

      def project_root
        File.dirname(File.dirname(File.dirname(@root)))
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
