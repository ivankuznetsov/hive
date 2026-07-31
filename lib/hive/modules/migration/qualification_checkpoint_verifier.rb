require "json"
require "hive/attempts/store"
require "hive/errors"
require "hive/modules/migration/bounded_directory_entries"
require "hive/modules/decision_journal"
require "hive/modules/event_ledger"
require "hive/modules/migration/occurrence_record_validator"
require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/qualification_checkpoint_evidence"
require "hive/modules/migration/qualification_event_validator"
require "hive/modules/migration/qualification_scenario_input"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Read-only host verifier for the durable boundary left by a candidate
      # process that exited with the private qualification checkpoint status.
      # It validates production records directly and binds the resulting facts
      # to the host snapshot; it never advances recovery state.
      class QualificationCheckpointVerifier
        ERROR =
          "patrol qualification checkpoint state is malformed".freeze
        EVENT_ID = /\Aevt-[0-9a-f]{64}\z/
        OCCURRENCE_FILE = /\Aocc-[0-9a-f]{64}\.json\z/
        EVENT_FILE = /\Aevt-[0-9a-f]{64}\.json\z/
        CAPTURE_FILE = /\Acap-[0-9a-f]{64}\.json\z/
        RECEIPT_FILE = /\Areceipt-[0-9a-f]{64}\.json\z/
        RECOVERY_FINGERPRINT = "qualification-recovery".freeze
        RECOVERY_FINGERPRINT_VALUE = {
          "state" => "qualification-recovered"
        }.freeze
        CONFLICT_FINGERPRINT_VALUE = {
          "state" => "qualification-conflict"
        }.freeze

        def initialize(
          evidence: QualificationCheckpointEvidence.new
        )
          unless evidence.respond_to?(:bind)
            raise Hive::ConfigError, ERROR
          end

          @evidence = evidence
        end

        def call(
          case_id:, generation:, checkpoint:, snapshot:,
          sandbox_root:, scenario_input:
        )
          unless
            scenario_input.is_a?(QualificationScenarioInput) &&
              scenario_input.module_name == "patrol" &&
              scenario_input.case_id == case_id.to_s &&
              generation.is_a?(Integer) &&
              generation.between?(1, 3)
            malformed!
          end
          root = validated_root(sandbox_root)
          facts = durable_facts(root)
          verify_checkpoint!(
            checkpoint.to_s,
            facts,
            generation: generation
          )
          @evidence.bind(
            checkpoint: checkpoint.to_s,
            snapshot: snapshot,
            facts: facts.merge(
              "generation" => generation
            )
          )
        rescue Hive::ConfigError => error
          raise error if error.message == ERROR

          malformed!
        rescue ArgumentError, EncodingError, KeyError, NoMethodError,
               TypeError, SystemCallError
          malformed!
        end

        private

        def durable_facts(root)
          hive_state = File.join(root, "hive-state")
          module_runtime = File.join(hive_state, "module-runtime")
          records = occurrence_records(hive_state)
          events = event_records(module_runtime)
          decisions = decision_records(module_runtime)
          attempts = attempt_records(root)
          captures = evidence_records(
            module_runtime,
            "captures",
            CAPTURE_FILE,
            PatrolCapture
          )
          receipts = evidence_records(
            module_runtime,
            "receipts",
            RECEIPT_FILE,
            EffectReceipt
          )
          effects = records.flat_map do |record|
            record.fetch("effects").values
          end
          pending_outbox = records.flat_map do |record|
            record.fetch("outbox").reject do |entry|
              entry.fetch("acknowledged")
            end
          end
          {
            "attempt_count" => attempts.length,
            "attempt_ids" =>
              attempts.map(&:attempt_id).sort,
            "attempt_states" =>
              attempts.map(&:state).sort,
            "capture_count" => captures.length,
            "decision_count" => decisions.length,
            "decision_ids" =>
              decisions.map { |row| row.fetch("decision_id") }.sort,
            "effect_states" =>
              effects.map { |cell| cell.fetch("state") }.sort,
            "event_count" => events.length,
            "event_ids" =>
              events.map { |row| row.fetch("event_id") }.sort,
            "recovery_fingerprint_state" =>
              recovery_fingerprint_state(hive_state),
            "occurrence_count" => records.length,
            "occurrence_phases" =>
              records.map { |row| row.fetch("phase") }.sort,
            "pending_outbox_kinds" =>
              pending_outbox.map do |entry|
                entry.fetch("kind")
              end.sort,
            "receipt_count" => receipts.length
          }.freeze
        end

        def verify_checkpoint!(checkpoint, facts, generation:)
          valid = case checkpoint
          when "after_legacy_capture"
            generation == 1 &&
              ordinary_reservation?(facts) &&
              facts.fetch("effect_states").empty? &&
              no_module_runtime?(facts)
          when "after_legacy_decision"
            generation == 1 &&
              facts.fetch("occurrence_count") == 1 &&
              facts.fetch("occurrence_phases") == [ "finalized" ] &&
              facts.fetch("pending_outbox_kinds").include?("capture") &&
              facts.fetch("pending_outbox_kinds").include?("event") &&
              facts.fetch("event_count").zero? &&
              facts.fetch("decision_count").zero? &&
              facts.fetch("attempt_count").zero?
          when "after_effect_intent"
            generation == 1 &&
              ordinary_reservation?(facts) &&
              facts.fetch("effect_states") == [ "prepared" ] &&
              facts.fetch("recovery_fingerprint_state") == "absent" &&
              no_module_runtime?(facts)
          when "before_effect_settlement"
            generation == 1 &&
              uncertain_effect?(facts) &&
              facts.fetch("recovery_fingerprint_state") == "recovered" &&
              no_module_runtime?(facts)
          when "during_reconciliation"
            generation == 2 &&
              uncertain_effect?(facts) &&
              facts.fetch("recovery_fingerprint_state") == "recovered" &&
              no_module_runtime?(facts)
          when "reconciliation_failure"
            generation == 2 &&
              uncertain_effect?(facts) &&
              facts.fetch("recovery_fingerprint_state") == "conflict" &&
              no_module_runtime?(facts)
          when "after_module_decision"
            generation == 1 &&
              facts.fetch("event_count") == 1 &&
              facts.fetch("capture_count") == 1 &&
              facts.fetch("decision_count").positive? &&
              facts.fetch("attempt_count") == 1 &&
              (
                facts.fetch("attempt_states") -
                  %w[launching running]
              ).empty?
          else
            false
          end
          malformed! unless valid
        end

        def ordinary_reservation?(facts)
          facts.fetch("occurrence_count") == 1 &&
            facts.fetch("occurrence_phases") == [ "reserved" ] &&
            facts.fetch("pending_outbox_kinds").empty?
        end

        def uncertain_effect?(facts)
          ordinary_reservation?(facts) &&
            facts.fetch("effect_states") == [ "dispatch_uncertain" ]
        end

        def no_module_runtime?(facts)
          facts.fetch("event_count").zero? &&
            facts.fetch("decision_count").zero? &&
            facts.fetch("attempt_count").zero?
        end

        def occurrence_records(hive_state)
          root = File.join(
            hive_state,
            "patrol",
            "occurrences"
          )
          validator = OccurrenceRecordValidator.new(
            module_name: "patrol"
          )
          json_records(root, OCCURRENCE_FILE).map do |name, bytes, value|
            occurrence_id = File.basename(name, ".json")
            malformed! unless
              bytes ==
                Hive::WorkflowPackage::CanonicalJSON.generate(value)
            validator.validate!(
              value,
              expected_id: occurrence_id
            )
            value.freeze
          end.freeze
        end

        def event_records(module_runtime)
          root = File.join(module_runtime, "events")
          json_records(root, EVENT_FILE).map do |name, bytes, value|
            expected_id = File.basename(name, ".json")
            malformed! unless
              bytes ==
                Hive::WorkflowPackage::CanonicalJSON.generate(value) &&
                EVENT_ID.match?(expected_id)
            validation = QualificationEventValidator.new.call(
              value,
              module_name: "patrol"
            )
            malformed! unless
              validation.event.fetch("event_id") == expected_id

            validation.event
          end.freeze
        rescue Hive::ConfigError => error
          raise error if error.message == ERROR

          malformed!
        end

        def decision_records(module_runtime)
          root = File.join(module_runtime, "decisions")
          return [].freeze unless File.directory?(root)

          Hive::Modules::DecisionJournal.new(
            root: module_runtime,
            create_directories: false
          ).all
        end

        def attempt_records(root)
          attempts = File.join(
            root,
            "hive-home",
            "attempts",
            "v2"
          )
          return [].freeze unless File.directory?(attempts)

          scan = Hive::Attempts::Store.new(
            root: attempts,
            create_directories: false
          ).scan
          malformed! unless scan.invalid_records.empty?

          scan.records
        end

        def evidence_records(module_runtime, kind, pattern, type)
          root = File.join(
            module_runtime,
            "migration",
            "patrol-evidence",
            kind
          )
          json_records(root, pattern).map do |_name, bytes, value|
            record = type.from_h(value)
            malformed! unless
              bytes ==
                Hive::WorkflowPackage::CanonicalJSON.generate(
                  record.to_h
                )
            record
          end.freeze
        end

        def fingerprints(hive_state)
          path = File.join(
            hive_state,
            "patrol",
            "fingerprints.json"
          )
          return {}.freeze unless File.file?(path)

          value = JSON.parse(File.binread(path))
          malformed! unless value.is_a?(Hash)

          value.freeze
        end

        def recovery_fingerprint_state(hive_state)
          value = fingerprints(hive_state).fetch(
            RECOVERY_FINGERPRINT,
            nil
          )
          case value
          when nil
            "absent"
          when RECOVERY_FINGERPRINT_VALUE
            "recovered"
          when CONFLICT_FINGERPRINT_VALUE
            "conflict"
          else
            "other"
          end.freeze
        end

        def json_records(root, pattern)
          return [].freeze unless File.directory?(root)

          names = BoundedDirectoryEntries.names(
            root,
            limit: QualificationCheckpointEvidence::MAX_ENTRIES
          ).select do |name|
            pattern.match?(name)
          end.sort
          names.map do |name|
            path = File.join(root, name)
            stat = File.lstat(path)
            malformed! unless
              stat.file? &&
                !stat.symlink? &&
                stat.uid == Process.euid &&
                (stat.mode & 0o022).zero?
            bytes = File.binread(path)
            [ name.freeze, bytes.freeze, JSON.parse(bytes) ].freeze
          end.freeze
        end

        def validated_root(value)
          path = File.expand_path(value.to_s)
          stat = File.lstat(path)
          malformed! unless
            path == value &&
              stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o022).zero? &&
              File.realpath(path) == path

          path.freeze
        end

        def malformed!
          raise Hive::ConfigError, ERROR
        end
      end
    end
  end
end
