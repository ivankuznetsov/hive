require "digest"
require "json"
require "open3"
require "hive/attempts/output_reference"
require "hive/attempts/store"
require "hive/modules/decision_journal"
require "hive/modules/event_ledger"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/occurrence_journal"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/shadow_comparator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Trusted host-side reconstruction of one completed candidate case.
      #
      # Terminal stores cannot reveal which previous process checkpoint was
      # interrupted or how many externally supervised generations executed.
      # Those claims remain explicitly unverified until LaneRunner supplies
      # independent process-generation custody.
      class QualificationScenarioEvidenceCollector
        ERROR =
          "patrol qualification host evidence is malformed".freeze
        MODULE_NAME = "patrol".freeze
        HOOK_ID = "scheduled-scan".freeze
        CASE_ID = /\A[a-z0-9][a-z0-9-]{0,127}\z/
        MAX_RAW_BYTES = 4 * 1024 * 1024
        TERMINAL_EFFECT_STATES = %w[
          committed denied failed reconciled
        ].freeze
        PASSIVE_DECISION_BINDINGS = [
          %w[architecture-patrol actions],
          %w[architecture-patrol merged-pr-discovery],
          %w[architecture-patrol scheduled-discovery],
          %w[architecture-patrol setup],
          %w[patrol setup],
          %w[patrol task-completed]
        ].map(&:freeze).freeze
        UNVERIFIED_CLAIMS = {
          "fault_checkpoint" =>
            "terminal state does not identify a prior process exit point",
          "restart_generation" =>
            "terminal state does not count supervised process generations",
          "recovery_trace" =>
            "candidate trace is not independent process custody",
          "pre_fault_durable_state_sha256" =>
            "candidate digest is not an externally timed pre-fault snapshot",
          "recovered_durable_state_sha256" =>
            "candidate digest is not an externally timed recovery snapshot"
        }.transform_values(&:freeze).freeze

        Projection = Data.define(
          :case_id, :module_name, :event, :decisions, :attempts,
          :comparator_record, :capture, :receipts, :bindings,
          :effect_index, :terminal_effects, :unverified_claims
        ) do
          SCHEMA =
            "hive-patrol-qualification-host-evidence".freeze
          SCHEMA_VERSION = 1

          def to_h
            {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "case_id" => case_id,
              "module" => module_name,
              "event" => event,
              "decisions" => decisions,
              "attempts" => attempts,
              "comparator_record" => comparator_record,
              "capture" => capture,
              "receipts" => receipts,
              "bindings" => bindings,
              "effect_index" => effect_index,
              "terminal_effects" => terminal_effects,
              "unverified_claims" => unverified_claims
            }.freeze
          end
        end

        def call(case_id:, sandbox_root:, candidate_row:)
          case_id = validated_case_id(case_id)
          root = validated_root(sandbox_root)
          row = validated_candidate_row(candidate_row, case_id)
          paths = evidence_paths(root)
          event = load_event(paths.fetch(:module_runtime))
          capture = capture_for(event)
          candidate_decisions, decisions = load_decisions(
            paths.fetch(:module_runtime),
            event: event,
            candidate: row
          )
          attempts, attempt_projections = load_attempts(
            paths.fetch(:attempts),
            event: event,
            decisions: candidate_decisions
          )
          comparator, effect_index = load_comparator(
            paths.fetch(:shadow),
            capture: capture
          )
          receipts = load_evidence(
            paths.fetch(:evidence),
            capture: capture,
            comparator: comparator
          )
          terminal_effects = load_terminal_effects(
            paths.fetch(:occurrences),
            capture: capture,
            receipts: receipts
          )
          repository_sha = repository_sha(paths.fetch(:repository))
          bind_candidate!(
            row,
            event: event,
            decisions: candidate_decisions,
            attempt_projections: attempt_projections,
            comparator: comparator,
            capture: capture,
            effect_index: effect_index,
            repository_sha: repository_sha
          )
          build_projection(
            case_id: case_id,
            event: event,
            decisions: decisions,
            candidate_decisions: candidate_decisions,
            attempts: attempts,
            comparator: comparator,
            capture: capture,
            receipts: receipts,
            effect_index: effect_index,
            terminal_effects: terminal_effects,
            repository_sha: repository_sha
          )
        rescue Hive::Error, JSON::ParserError, KeyError, IndexError,
               ArgumentError, TypeError, NoMethodError, EncodingError,
               SystemCallError
          malformed!
        end

        private

        def validated_case_id(value)
          id = value.to_s
          malformed! unless CASE_ID.match?(id)

          id.freeze
        end

        def validated_root(value)
          path = File.expand_path(value.to_s)
          stat = File.lstat(path)
          malformed! unless stat.directory? &&
                            !stat.symlink? &&
                            File.realpath(path) == path

          path.freeze
        end

        def validated_candidate_row(value, case_id)
          actuals = QualificationScenarioActuals.from_h(
            "schema" => QualificationScenarioActuals::SCHEMA,
            "schema_version" =>
              QualificationScenarioActuals::SCHEMA_VERSION,
            "actuals" => [ value ]
          ).actuals
          malformed! unless actuals.length == 1 &&
                            actuals.fetch(0).fetch("case_id") == case_id

          actuals.fetch(0)
        end

        def evidence_paths(root)
          paths = {
            repository: required_directory(root, "repository"),
            hive_state: required_directory(root, "hive-state"),
            attempts:
              required_directory(root, "hive-home/attempts/v2")
          }
          runtime = required_directory(
            paths.fetch(:hive_state), "module-runtime"
          )
          migration = required_directory(runtime, "migration")
          paths.merge(
            module_runtime: runtime,
            shadow: required_directory(migration, "shadow"),
            evidence:
              required_directory(migration, "patrol-evidence"),
            occurrences:
              required_directory(
                paths.fetch(:hive_state),
                "patrol/occurrences"
              )
          ).freeze
        end

        def required_directory(root, relative)
          path = File.expand_path(relative, root)
          stat = File.lstat(path)
          prefix = "#{File.realpath(root)}#{File::SEPARATOR}"
          malformed! unless stat.directory? &&
                            !stat.symlink? &&
                            File.realpath(path).start_with?(prefix)

          path.freeze
        end

        def load_event(module_runtime)
          events_root = required_directory(
            module_runtime, "events"
          )
          names = exact_names!(
            events_root,
            /\A(?:evt-[0-9a-f]{64}|index)\.json\z/
          )
          malformed! unless names.count do |name|
            name.start_with?("evt-")
          end == 1 && names.include?("index.json")

          raw_index = canonical_object(
            File.join(events_root, "index.json")
          )
          events = Hive::Modules::EventLedger.new(
            root: module_runtime
          ).all
          malformed! unless events.length == 1

          event = events.fetch(0)
          schedule_key = [
            event.dig("payload", "target_module"),
            event.dig("payload", "schedule")
          ].join("\0")
          malformed! unless
            raw_index.keys.sort ==
              %w[event_ids latest_schedules schema_version] &&
              raw_index["schema_version"] == 1 &&
              raw_index["event_ids"] == [ event.fetch("event_id") ] &&
              raw_index["latest_schedules"] == {
                schedule_key => event.fetch("occurred_at")
              }
          event
        end

        def capture_for(event)
          capture = PatrolCapture.from_h(
            event.dig(
              "payload",
              "legacy_mutator_capture"
            )
          )
          project = capture.project
          valid =
            capture.module_name == MODULE_NAME &&
            event.fetch("event_name") == "schedule" &&
            event.fetch("project_id") ==
              project.fetch("project_id") &&
            event.fetch("project") == project.fetch("name") &&
            event.dig("payload", "target_module") == MODULE_NAME
          malformed! unless valid

          capture
        end

        def load_decisions(module_runtime, event:, candidate:)
          root = required_directory(module_runtime, "decisions")
          names = exact_names!(
            root, /\Adec-[0-9a-f]{64}\.json\z/
          )
          decisions = Hive::Modules::DecisionJournal.new(
            root: module_runtime,
            create_directories: false
          ).all
          malformed! unless decisions.length == names.length
          decisions.each do |decision|
            malformed! unless
              decision.fetch("event_id") == event.fetch("event_id") &&
              decision.fetch("event_name") ==
                event.fetch("event_name") &&
              decision.fetch("project_id") ==
                event.fetch("project_id") &&
              decision.fetch("project") == event.fetch("project")
          end

          relevant = decisions.select do |decision|
            decision["module"] == MODULE_NAME &&
              decision["hook"] == HOOK_ID
          end.sort_by do |decision|
            [
              admitted?(decision) ? 0 : 1,
              decision.fetch("evaluated_at"),
              decision.fetch("decision_id")
            ]
          end
          passive = decisions - relevant
          bindings = passive.map do |decision|
            [ decision.fetch("module"), decision.fetch("hook") ]
          end.sort
          malformed! unless
            !relevant.empty? &&
              candidate.fetch("decisions") == relevant &&
              bindings.uniq == PASSIVE_DECISION_BINDINGS &&
              passive.all? do |decision|
                decision.fetch("outcome") == "skip" &&
                  decision.fetch("reason") == "hook_disabled" &&
                  decision["attempt_id"].nil?
              end
          [ relevant.freeze, decisions.freeze ].freeze
        end

        def admitted?(decision)
          decision["outcome"] == "launch" &&
            decision["reason"] == "admitted"
        end

        def load_attempts(root, event:, decisions:)
          records_root = required_directory(root, "records")
          names = exact_names!(
            records_root,
            /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json\z/
          )
          scan = Hive::Attempts::Store.new(
            root: root,
            create_directories: false
          ).scan
          record_names = scan.records.map do |record|
            "#{record.attempt_id}.json"
          end.sort
          malformed! unless scan.invalid_records.empty? &&
                            scan.records.length == names.length &&
                            names == record_names &&
                            !scan.records.empty?
          records = scan.records
          records.each do |record|
            subject = record.subject
            malformed! unless
              record.module_hook? &&
              subject["project_id"] ==
                event.fetch("project_id") &&
              subject["event_id"] ==
                event.fetch("event_id") &&
              subject["module"] == MODULE_NAME &&
              subject["hook"] == HOOK_ID
          end
          lineage = attempt_lineage(records, root: root)
          first_id = lineage.fetch(0).attempt_id
          primary = decisions.select do |decision|
            admitted?(decision) ||
              (
                decision["outcome"] == "skip" &&
                decision["reason"] == "launch_handoff_failed"
              )
          end
          malformed! unless primary.length == 1 &&
                            primary.fetch(0).fetch("attempt_id") ==
                              first_id
          projections =
            lineage.map { |record| attempt_projection(record) }.freeze
          [
            immutable_json(lineage.map(&:to_h)),
            projections
          ].freeze
        end

        def attempt_lineage(records, root:)
          successful = records.select do |record|
            record.state == "terminal" &&
              record.outcome == "succeeded"
          end
          malformed! unless successful.length == 1 &&
                            records.all?(&:final?)

          by_id = records.to_h do |record|
            [ record.attempt_id, record ]
          end
          malformed! unless by_id.length == records.length
          lineage = []
          current = successful.fetch(0)
          while current
            lineage << current
            predecessor_id = current["predecessor_attempt_id"]
            current = predecessor_id && by_id.fetch(predecessor_id)
          end
          lineage.reverse!
          valid =
            lineage.length == records.length &&
            lineage.fetch(0)["predecessor_attempt_id"].nil? &&
            lineage.fetch(0)["retry_charge"].zero? &&
            lineage.each_cons(2).all? do |before, after|
              after["predecessor_attempt_id"] ==
                before.attempt_id &&
                after["retry_charge"] ==
                  before["retry_charge"] + 1
            end
          terminal = lineage.last
          valid &&=
            terminal.wrapper.is_a?(Hash) &&
            terminal.worker.is_a?(Hash) &&
            Hive::Attempts::OutputReference.verify(
              terminal.receipt.fetch("log_reference"),
              root: root
            )
          malformed! unless valid

          lineage.freeze
        end

        def attempt_projection(record)
          value = record.to_h.slice(
            "attempt_id",
            "predecessor_attempt_id",
            "retry_charge",
            "state",
            "outcome",
            "task_generation",
            "ownership_generation",
            "task_input_epoch",
            "subject",
            "receipt",
            "loss"
          )
          value["receipt_sha256"] =
            value["receipt"] &&
            Digest::SHA256.hexdigest(canonical(value["receipt"]))
          value["projection_sha256"] =
            Digest::SHA256.hexdigest(canonical(value))
          immutable_json(value)
        end

        def load_comparator(root, capture:)
          validate_shadow_inventory!(root)
          records =
            ShadowComparator.new(root: root).each_record.to_a
          malformed! unless records.length == 1

          record = records.fetch(0)
          index = PatrolEffectIndex.build(records: records)
          malformed! unless
            record.fetch("module") == MODULE_NAME &&
              record.fetch("comparable") == true &&
              record.fetch("evidence_source") ==
                "legacy_mutator_capture" &&
              record.fetch("legacy_capture") == capture.to_h &&
              record.fetch("unexplained_differences").empty? &&
              record.fetch("duplicate_effects").empty? &&
              record.fetch("module_effects").empty? &&
              index.duplicate_keys.empty?
          [ record, index ].freeze
        end

        def load_evidence(root, capture:, comparator:)
          %w[
            captures receipts indexes/occurrences indexes/intents
          ].each do |relative|
            required_directory(root, relative)
          end
          store = EvidenceStore.new(root: root)
          captures = store.captures
          receipts = store.receipts
          malformed! unless captures.length == 1 &&
                            captures.fetch(0).to_h == capture.to_h

          receipt_ids = receipts.map(&:receipt_id).sort
          intent_ids = receipts.map { |receipt| receipt.intent.intent_id }
          expected_ids = capture.effect_ids.sort
          comparator_receipts =
            comparator.fetch("legacy_effects").sort_by do |receipt|
              receipt.fetch("receipt_id")
            end
          malformed! unless
            receipt_ids == expected_ids &&
              receipt_ids.uniq == receipt_ids &&
              intent_ids.uniq == intent_ids &&
              receipts.all? do |receipt|
                intent = receipt.intent
                intent.module_name == MODULE_NAME &&
                  intent.authority == "legacy" &&
                  intent.occurrence_id ==
                    capture.occurrence_id &&
                  TERMINAL_EFFECT_STATES.include?(
                    receipt.status
                  )
              end &&
              receipts.map(&:to_h).sort_by do |receipt|
                receipt.fetch("receipt_id")
              end == comparator_receipts
          validate_evidence_indexes!(
            root, store: store, capture: capture, receipts: receipts
          )
          immutable_json(
            receipts.sort_by(&:receipt_id).map(&:to_h)
          )
        end

        def validate_evidence_indexes!(root, store:, capture:, receipts:)
          occurrence_page = store.receipts_for_occurrence(
            capture.occurrence_id,
            limit: EvidenceStore::MAX_PAGE_SIZE
          )
          malformed! unless occurrence_page.next_cursor.nil? &&
                            occurrence_page.records
                              .map(&:receipt_id).sort ==
                              receipts.map(&:receipt_id).sort
          receipts.each do |receipt|
            page = store.receipts_for_intent(
              receipt.intent.intent_id,
              limit: EvidenceStore::MAX_PAGE_SIZE
            )
            malformed! unless page.next_cursor.nil? &&
                              page.records.map(&:receipt_id) ==
                                [ receipt.receipt_id ]
          end
          occurrence_names = exact_names!(
            File.join(root, "indexes", "occurrences"),
            /\Aocc-[0-9a-f]{64}\.json\z/
          )
          intent_names = exact_names!(
            File.join(root, "indexes", "intents"),
            /\Aintent-[0-9a-f]{64}\.json\z/
          )
          expected_occurrence_names =
            if receipts.empty?
              []
            else
              [ "#{capture.occurrence_id}.json" ]
            end
          malformed! unless occurrence_names ==
                            expected_occurrence_names &&
                            intent_names ==
                              receipts.map do |receipt|
                                "#{receipt.intent.intent_id}.json"
                              end.sort
        end

        def load_terminal_effects(root, capture:, receipts:)
          validate_occurrence_inventory!(root)
          validate_recovery_index!(root)
          journal = OccurrenceJournal.new(
            root, module_name: MODULE_NAME
          )
          records = journal.each_record.to_a
          malformed! unless records.length <= 1

          proof =
            if records.empty?
              validate_retirement_state!(root, capture)
              malformed! unless journal.terminalized?(capture)
              "retired_fence"
            else
              validate_live_occurrence!(
                records.fetch(0),
                capture: capture,
                receipts: receipts
              )
              "live_finalized_record"
            end
          immutable_json(
            "occurrence_id" => capture.occurrence_id,
            "occurrence_proof" => proof,
            "effect_count" => receipts.length,
            "pending_effect_count" => 0,
            "pending_outbox_count" => 0,
            "duplicate_intent_ids" => [],
            "duplicate_receipt_ids" => []
          )
        end

        def validate_live_occurrence!(record, capture:, receipts:)
          cells = record.fetch("effects")
          by_intent = receipts.to_h do |receipt|
            [ receipt.fetch("intent").fetch("intent_id"), receipt ]
          end
          valid =
            record.fetch("occurrence_id") ==
              capture.occurrence_id &&
            record.fetch("phase") == "finalized" &&
            record.fetch("final_capture") == capture.to_h &&
            cells.keys.sort == by_intent.keys.sort &&
            record.fetch("outbox").all? do |entry|
              entry.fetch("acknowledged") == true
            end &&
            cells.all? do |intent_id, cell|
              receipt = by_intent.fetch(intent_id)
              TERMINAL_EFFECT_STATES.include?(
                cell.fetch("state")
              ) &&
                cell.fetch("terminal_receipt_id") ==
                  receipt.fetch("receipt_id") &&
                cell.fetch("receipt_ids") ==
                  [ receipt.fetch("receipt_id") ]
            end
          malformed! unless valid
        end

        def validate_recovery_index!(root)
          index = canonical_object(
            File.join(root, "recovery-index.json")
          )
          malformed! unless
            index.keys.sort == %w[
              generation module occurrence_ids schema schema_version
            ] &&
              index["schema"] ==
                "hive-patrol-occurrence-recovery-index" &&
              index["schema_version"] == 1 &&
              index["module"] == MODULE_NAME &&
              index["occurrence_ids"] == []
        end

        def validate_retirement_state!(root, capture)
          state = canonical_object(
            File.join(root, "journal-state.json")
          )
          malformed! unless
            state["schema"] ==
              "hive-patrol-occurrence-journal-state" &&
              state["schema_version"] == 1 &&
              state["module"] == MODULE_NAME &&
              state["recovery_failure"].nil? &&
              state["recovery_inventory_dirty"] == false
          reservation = capture.reservation
          if reservation.key?("attempt_generation")
            entries = state.fetch("sequence_high_waters")
            expected_digest =
              Digest::SHA256.hexdigest(
                reservation.fetch("id")
              )
            malformed! unless
              entries.length == 1 &&
                entries.fetch(0) == {
                  "identity_digest" => expected_digest,
                  "window_started_at" =>
                    reservation.fetch("window_started_at"),
                  "high_water" =>
                    reservation.fetch("attempt_generation"),
                  "closed" => true
                } &&
                state.fetch(
                  "retired_occurrence_digests"
                ).empty?
          else
            malformed! unless
              state.fetch("sequence_high_waters").empty? &&
                state.fetch("retired_occurrence_digests") ==
                  [
                    Digest::SHA256.hexdigest(
                      capture.occurrence_id
                    )
                  ]
          end
        end

        def repository_sha(root)
          stdout, _stderr, status = Open3.capture3(
            "git", "-C", root, "rev-parse", "HEAD"
          )
          sha = stdout.strip
          malformed! unless status.success? &&
                            sha.match?(/\A[0-9a-f]{40}\z/)

          sha.freeze
        end

        def bind_candidate!(
          candidate, event:, decisions:, attempt_projections:,
          comparator:, capture:, effect_index:, repository_sha:
        )
          expected = {
            "module" => MODULE_NAME,
            "event_id" => event.fetch("event_id"),
            "event" => event,
            "decision_id" =>
              comparator.fetch("decision_id"),
            "trigger_digest" =>
              comparator.fetch("trigger_digest"),
            "comparator_semantic_digest" =>
              comparator.fetch("semantic_digest"),
            "legacy_capture_id" => capture.capture_id,
            "legacy_effect_keys" => effect_index.legacy_keys,
            "module_effect_keys" =>
              effect_index.entries
                .select do |entry|
                  entry["channel"] == "module"
                end
                .map do |entry|
                  entry.fetch("effect_key")
                end.sort,
            "repository_sha" => repository_sha,
            "decisions" => decisions,
            "attempts" => attempt_projections
          }
          malformed! unless expected.all? do |key, value|
            candidate.fetch(key) == value
          end
        end

        def build_projection(
          case_id:, event:, decisions:, attempts:, comparator:,
          capture:, receipts:, effect_index:, terminal_effects:,
          repository_sha:, candidate_decisions:
        )
          bindings = immutable_json(
            "event_id" => event.fetch("event_id"),
            "decision_ids" =>
              decisions.map do |decision|
                decision.fetch("decision_id")
              end,
            "candidate_decision_ids" =>
              candidate_decisions.map do |decision|
                decision.fetch("decision_id")
              end,
            "attempt_ids" =>
              attempts.map do |attempt|
                attempt.fetch("attempt_id")
              end,
            "comparator_decision_id" =>
              comparator.fetch("decision_id"),
            "capture_id" => capture.capture_id,
            "occurrence_id" => capture.occurrence_id,
            "intent_ids" =>
              receipts.map do |receipt|
                receipt.fetch("intent").fetch("intent_id")
              end.sort,
            "receipt_ids" =>
              receipts.map do |receipt|
                receipt.fetch("receipt_id")
              end.sort,
            "repository_sha" => repository_sha
          )
          Projection.new(
            case_id: case_id,
            module_name: MODULE_NAME,
            event: immutable_json(event),
            decisions: immutable_json(decisions),
            attempts: attempts,
            comparator_record: immutable_json(comparator),
            capture: immutable_json(capture.to_h),
            receipts: receipts,
            bindings: bindings,
            effect_index: immutable_json(effect_index.to_h),
            terminal_effects: terminal_effects,
            unverified_claims:
              immutable_json(UNVERIFIED_CLAIMS)
          ).freeze
        end

        def validate_shadow_inventory!(root)
          entries = Dir.children(root).sort
          malformed! unless entries.all? do |name|
            path = File.join(root, name)
            case name
            when "patrol", "architecture-patrol"
              stat = File.lstat(path)
              stat.directory? &&
                !stat.symlink? &&
                begin
                  exact_names!(
                    path, /\A[0-9a-f]{64}\.json\z/
                  )
                  true
                end
            when "migrations"
              stat = File.lstat(path)
              stat.directory? &&
                !stat.symlink? &&
                exact_names!(
                  path,
                  /\Ashadow-decision-v2(?:-checkpoint)?\.json\z/
                ).sort == %w[
                  shadow-decision-v2-checkpoint.json
                  shadow-decision-v2.json
                ]
            else
              false
            end
          end
        end

        def validate_occurrence_inventory!(root)
          json_names = Dir.children(root)
                          .select { |name| name.end_with?(".json") }
                          .sort
          valid = json_names.all? do |name|
            /\A(?:journal-state|recovery-index|occ-[0-9a-f]{64})\.json\z/
              .match?(name) &&
              begin
                stat = File.lstat(File.join(root, name))
                stat.file? && !stat.symlink?
              end
          end
          malformed! unless valid &&
                            json_names.include?("journal-state.json") &&
                            json_names.include?("recovery-index.json")
        end

        def exact_names!(root, pattern)
          entries = Dir.children(root).sort
          malformed! unless entries.all? do |name|
            path = File.join(root, name)
            stat = File.lstat(path)
            stat.file? && !stat.symlink? && pattern.match?(name)
          end

          entries.freeze
        end

        def canonical_object(path)
          stat = File.lstat(path)
          malformed! unless stat.file? &&
                            !stat.symlink? &&
                            stat.size <= MAX_RAW_BYTES

          bytes = File.binread(path)
          value = JSON.parse(bytes)
          malformed! unless value.is_a?(Hash) &&
                            bytes == canonical(value)

          value
        end

        def immutable_json(value)
          PatrolEvidence.immutable_json(
            value,
            label: "patrol qualification host evidence"
          )
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def malformed!
          raise Hive::ConfigError, ERROR
        end
      end
    end
  end
end
