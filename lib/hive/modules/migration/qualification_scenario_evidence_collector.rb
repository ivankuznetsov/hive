require "digest"
require "json"
require "open3"
require "hive/attempts/output_reference"
require "hive/attempts/store"
require "hive/modules/decision_journal"
require "hive/modules/event_ledger"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/bounded_directory_entries"
require "hive/modules/migration/occurrence_record_validator"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/shadow_comparator"
require "hive/refactor_patrol/architecture_project_binding"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/pr_manifest"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Trusted host-side reconstruction of one completed candidate case.
      #
      # This projection deliberately marks process-generation claims
      # unverified: terminal stores cannot reveal which prior process stopped
      # or count externally supervised generations. LaneRunner resolves those
      # claims separately from host-owned checkpoint snapshots and receipts.
      class QualificationScenarioEvidenceCollector
        ERROR =
          "patrol qualification host evidence is malformed".freeze
        PRIMARY_HOOKS = {
          "architecture-patrol" =>
            %w[actions scheduled-discovery].freeze,
          "patrol" => %w[scheduled-scan].freeze
        }.freeze
        CASE_ID = QualificationRunDescriptor::SAFE_ID
        MAX_RAW_BYTES = 4 * 1024 * 1024
        MAX_DIRECTORY_ENTRIES = 8_192
        TERMINAL_EFFECT_STATES = %w[
          committed denied failed reconciled
        ].freeze
        ARCHITECTURE_SCHEDULE = "*/10 * * * *".freeze
        JOURNAL_STATE_KEYS = %w[
          module recovery_failure recovery_generation
          recovery_inventory_dirty recovery_inventory_generation
          retired_occurrence_digests schema schema_version
          sequence_closed_through sequence_high_waters
        ].freeze
        ALL_DECISION_BINDINGS = [
          %w[architecture-patrol actions],
          %w[architecture-patrol merged-pr-discovery],
          %w[architecture-patrol scheduled-discovery],
          %w[architecture-patrol setup],
          %w[patrol scheduled-scan],
          %w[patrol setup],
          %w[patrol task-completed]
        ].map(&:freeze).freeze
        UNVERIFIED_CLAIMS = {
          "fault_checkpoint" =>
            "terminal state does not identify a prior process exit point",
          "restart_generation" =>
            "terminal state does not count supervised process generations",
          "recovery_trace" =>
            "terminal stores do not contain process-generation custody",
          "pre_fault_durable_state_sha256" =>
            "candidate digest is not an externally timed pre-fault snapshot",
          "recovered_durable_state_sha256" =>
            "candidate digest is not an externally timed recovery snapshot"
        }.transform_values(&:freeze).freeze

        Projection = Data.define(
          :case_id, :module_name, :event, :decisions, :attempts,
          :comparator_record, :capture, :receipts, :bindings,
          :effect_index, :terminal_effects, :product_state,
          :unverified_claims
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
              "product_state" => product_state,
              "unverified_claims" => unverified_claims
            }.freeze
          end
        end

        def call(case_id:, sandbox_root:, candidate_row:)
          case_id = validated_case_id(case_id)
          root = validated_root(sandbox_root)
          row = validated_candidate_row(candidate_row, case_id)
          module_name = row.fetch("module")
          paths = evidence_paths(root, module_name)
          event = load_event(paths.fetch(:module_runtime))
          hook_id = primary_hook(event, module_name)
          capture = capture_for(event, module_name)
          candidate_decisions, decisions = load_decisions(
            paths.fetch(:module_runtime),
            event: event,
            candidate: row,
            module_name: module_name,
            hook_id: hook_id
          )
          attempts, attempt_projections = load_attempts(
            paths.fetch(:attempts),
            event: event,
            decisions: candidate_decisions,
            module_name: module_name,
            hook_id: hook_id
          )
          comparator, effect_index = load_comparator(
            paths.fetch(:shadow),
            capture: capture,
            module_name: module_name
          )
          receipts = load_evidence(
            paths.fetch(:evidence),
            capture: capture,
            comparator: comparator,
            module_name: module_name
          )
          terminal_effects = load_terminal_effects(
            paths.fetch(:occurrences),
            capture: capture,
            receipts: receipts,
            module_name: module_name
          )
          repository_sha = repository_sha(paths.fetch(:repository))
          product_state = load_product_state(
            paths,
            capture: capture,
            event: event,
            module_name: module_name,
            hook_id: hook_id,
            repository_sha: repository_sha,
            receipts: receipts
          )
          bind_candidate!(
            row,
            event: event,
            decisions: candidate_decisions,
            attempt_projections: attempt_projections,
            comparator: comparator,
            capture: capture,
            effect_index: effect_index,
            repository_sha: repository_sha,
            module_name: module_name
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
            repository_sha: repository_sha,
            module_name: module_name,
            product_state: product_state
          )
        rescue Hive::Error, Hive::RefactorPatrol::JobStore::Error,
               JSON::ParserError, KeyError, IndexError,
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

        def evidence_paths(root, module_name)
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
                occurrence_path(module_name)
              )
          ).freeze
        end

        def occurrence_path(module_name)
          case module_name
          when "patrol"
            "patrol/occurrences"
          when "architecture-patrol"
            "refactor_patrol/v3/occurrences/records"
          else
            malformed!
          end
        end

        def required_directory(root, relative)
          path = File.expand_path(relative, root)
          stat = File.lstat(path)
          prefix = "#{File.realpath(root)}#{File::SEPARATOR}"
          malformed! unless stat.directory? &&
                            !stat.symlink? &&
                            stat.uid == Process.euid &&
                            (stat.mode & 0o022).zero? &&
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
          event_name = names.find do |name|
            name.start_with?("evt-")
          end
          event_id = File.basename(event_name, ".json")
          event_bytes = canonical_bytes(
            File.join(events_root, event_name)
          )
          event = Hive::Modules::EventLedger.parse_snapshot(
            event_bytes,
            expected_id: event_id
          )
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

        def primary_hook(event, module_name)
          hook_id =
            event.dig("payload", "target_hook") ||
            "scheduled-scan"
          malformed! unless
            PRIMARY_HOOKS.fetch(module_name).include?(hook_id)

          hook_id.freeze
        end

        def capture_for(event, module_name)
          capture = PatrolCapture.from_h(
            event.dig(
              "payload",
              "legacy_mutator_capture"
            )
          )
          project = capture.project
          source_type =
            module_name == "patrol" ?
              "legacy_patrol_completion" :
              "legacy_architecture_patrol_completion"
          idempotency_prefix =
            module_name == "patrol" ?
              "patrol-finalized:" :
              "architecture-patrol-finalized:"
          valid =
            capture.module_name == module_name &&
            event.fetch("event_name") == "schedule" &&
            event.fetch("project_id") ==
              project.fetch("project_id") &&
            event.fetch("project") == project.fetch("name") &&
            event.dig("payload", "target_module") == module_name &&
            event.fetch("source") == {
              "type" => source_type,
              "id" => capture.occurrence_id
            } &&
            event.fetch("idempotency_key") ==
              "#{idempotency_prefix}#{capture.occurrence_id}"
          payload = event.fetch("payload")
          payload_keys = %w[
            due_at legacy_mutator_capture missed_windows schedule
            target_module
          ]
          payload_keys << "target_hook" if
            module_name == "architecture-patrol"
          valid &&=
            payload.keys.sort == payload_keys.sort &&
            event.fetch("occurred_at") ==
              capture.occurred_at &&
            event.fetch("recorded_at") ==
              capture.recorded_at &&
            payload.fetch("due_at") ==
              capture.occurred_at &&
            payload.fetch("missed_windows") == 0
          valid &&=
            payload.fetch("schedule") ==
              ARCHITECTURE_SCHEDULE if
                module_name == "architecture-patrol"
          malformed! unless valid

          capture
        end

        def load_decisions(
          module_runtime, event:, candidate:, module_name:, hook_id:
        )
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
            decision["module"] == module_name &&
              decision["hook"] == hook_id
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
          passive_bindings =
            ALL_DECISION_BINDINGS.reject do |binding|
              binding == [ module_name, hook_id ]
            end.sort
          malformed! unless
            !relevant.empty? &&
              candidate.fetch("decisions") == relevant &&
              bindings.uniq == passive_bindings &&
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

        def load_attempts(
          root, event:, decisions:, module_name:, hook_id:
        )
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
              subject["module"] == module_name &&
              subject["hook"] == hook_id
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

        def load_comparator(root, capture:, module_name:)
          validate_shadow_inventory!(root)
          records =
            ShadowComparator.new(
              root: root,
              admission_lock: lambda do |shared: true, &block|
                malformed! unless shared == true && block
                block.call
              end
            ).each_record.to_a
          malformed! unless records.length == 1

          record = records.fetch(0)
          index = PatrolEffectIndex.build(records: records)
          malformed! unless
            record.fetch("module") == module_name &&
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

        def load_evidence(root, capture:, comparator:, module_name:)
          %w[
            captures receipts indexes/occurrences indexes/intents
          ].each do |relative|
            required_directory(root, relative)
          end
          captures = load_evidence_records(
            File.join(root, "captures"),
            pattern: /\Acap-[0-9a-f]{64}\.json\z/,
            type: PatrolCapture
          )
          receipts = load_evidence_records(
            File.join(root, "receipts"),
            pattern: /\Areceipt-[0-9a-f]{64}\.json\z/,
            type: EffectReceipt
          )
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
                intent.module_name == module_name &&
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
            root, capture: capture, receipts: receipts
          )
          immutable_json(
            receipts.sort_by(&:receipt_id).map(&:to_h)
          )
        end

        def load_evidence_records(root, pattern:, type:)
          exact_names!(root, pattern).map do |name|
            value, bytes = json_file(File.join(root, name))
            record = type.from_h(value)
            identity =
              type == PatrolCapture ?
                record.capture_id : record.receipt_id
            malformed! unless
              name == "#{identity}.json" &&
                bytes == canonical(record.to_h)
            record
          end.freeze
        end

        def validate_evidence_indexes!(root, capture:, receipts:)
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
          if receipts.empty?
            return
          end

          validate_evidence_index!(
            File.join(
              root,
              "indexes",
              "occurrences",
              "#{capture.occurrence_id}.json"
            ),
            kind: "occurrence",
            identity: capture.occurrence_id,
            receipt_ids: receipts.map(&:receipt_id).sort
          )
          receipts.each do |receipt|
            validate_evidence_index!(
              File.join(
                root,
                "indexes",
                "intents",
                "#{receipt.intent.intent_id}.json"
              ),
              kind: "intent",
              identity: receipt.intent.intent_id,
              receipt_ids: [ receipt.receipt_id ]
            )
          end
        end

        def validate_evidence_index!(
          path, kind:, identity:, receipt_ids:
        )
          value = canonical_object(path)
          malformed! unless
            value.keys.sort == %w[
              identity kind receipt_ids schema schema_version
            ] &&
              value.fetch("schema") ==
                EvidenceStore::INDEX_SCHEMA &&
              value.fetch("schema_version") == 1 &&
              value.fetch("kind") == kind &&
              value.fetch("identity") == identity &&
              value.fetch("receipt_ids") == receipt_ids
        end

        def load_terminal_effects(
          root, capture:, receipts:, module_name:
        )
          occurrence_names = validate_occurrence_inventory!(root)
          recovery_index =
            validate_recovery_index!(root, module_name)
          validator = OccurrenceRecordValidator.new(
            module_name: module_name
          )
          records = occurrence_names.filter_map do |name|
            next unless name.start_with?("occ-")

            value = canonical_object(File.join(root, name))
            validator.validate!(
              value,
              expected_id: File.basename(name, ".json")
            )
            immutable_json(value)
          end
          malformed! unless records.length <= 1

          journal_state = nil
          proof =
            if records.empty?
              journal_state = validate_retirement_state!(
                root, capture, module_name
              )
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
            "duplicate_receipt_ids" => [],
            "journal_state" => journal_state,
            "recovery_index" => recovery_index
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

        def validate_recovery_index!(root, module_name)
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
              index["module"] == module_name &&
              index["occurrence_ids"] == []
          if module_name == "architecture-patrol"
            malformed! unless index["generation"] == 2
          end
          index
        end

        def validate_retirement_state!(root, capture, module_name)
          state = canonical_object(
            File.join(root, "journal-state.json")
          )
          malformed! unless
            state.keys.sort == JOURNAL_STATE_KEYS.sort &&
            state["schema"] ==
              "hive-patrol-occurrence-journal-state" &&
              state["schema_version"] == 1 &&
              state["module"] == module_name &&
              state["recovery_failure"].nil? &&
              state["recovery_inventory_dirty"] == false
          if module_name == "architecture-patrol"
            malformed! unless
              state["recovery_generation"] == 0 &&
                state["recovery_inventory_generation"] == 2 &&
                state["sequence_closed_through"].nil? &&
                state["retired_occurrence_digests"].empty?
          end
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
          state
        end

        def load_product_state(
          paths, capture:, event:, module_name:, hook_id:,
          repository_sha:, receipts:
        )
          return ordinary_product_state(capture) if
            module_name == "patrol"

          architecture_product_state(
            paths,
            capture: capture,
            event: event,
            hook_id: hook_id,
            repository_sha: repository_sha,
            receipts: receipts
          )
        end

        def ordinary_product_state(capture)
          immutable_json(
            "type" => "ordinary_patrol_occurrence",
            "occurrence_id" => capture.occurrence_id,
            "retired" => true
          )
        end

        def architecture_product_state(
          paths, capture:, event:, hook_id:, repository_sha:,
          receipts:
        )
          outcome = capture.outcome
          job_id = outcome.fetch("job_id")
          project = architecture_project(
            paths,
            capture: capture
          )
          store = Hive::RefactorPatrol::JobStore.new(
            paths.fetch(:repository),
            hive_state_path: paths.fetch(:hive_state),
            project: project
          )
          jobs = store.jobs
          malformed! unless jobs.length == 1 &&
                            jobs.fetch(0).fetch("job_id") == job_id

          aggregate = jobs.fetch(0)
          manifest = architecture_manifest(
            paths.fetch(:hive_state),
            job_id: job_id,
            registration: capture.project.fetch("name")
          )
          source = manifest.fetch("source")
          aggregate_source = source.merge(
            "changed_paths" => manifest.fetch("changed_paths"),
            "manifest_checksum" =>
              manifest.fetch("manifest_checksum")
          )
          actions = aggregate.fetch("actions")
          transition_intent_ids =
            architecture_transition_intent_ids(aggregate)
          receipt_intent_ids = receipts.map do |receipt|
            receipt.fetch("intent").fetch("intent_id")
          end.sort
          action_outcomes = actions.to_h do |action|
            [
              action.fetch("canonical_action_id"),
              action.fetch("outcome")
            ]
          end
          expected_hook =
            actions.empty? ? "scheduled-discovery" : "actions"
          valid =
            aggregate.fetch("source") == aggregate_source &&
            aggregate.fetch("analysis_sha") ==
              source.fetch("merge_sha") &&
            aggregate.fetch("occurrence_id") ==
              capture.occurrence_id &&
            aggregate.fetch("state") == outcome.fetch("state") &&
            aggregate.fetch("complete") == true &&
            aggregate.fetch("review_errors").empty? &&
            outcome.fetch("complete") == true &&
            aggregate.fetch("zero_reason") ==
              outcome.fetch("zero_reason") &&
            outcome.fetch("action_count") == actions.length &&
            outcome.fetch("action_outcomes") == action_outcomes &&
            outcome.fetch("completion_status") == "closed" &&
            capture.reservation.fetch("kind") ==
              "architecture" &&
            capture.reservation.fetch("id") == job_id &&
            capture.reservation.fetch("job_id") == job_id &&
            capture.trigger.fetch("manifest_digest") ==
              manifest.fetch("manifest_checksum") &&
            capture.trigger.fetch("merge_sha") ==
              source.fetch("merge_sha") &&
            source.fetch("merge_sha") == repository_sha &&
            hook_id == expected_hook &&
            event.dig("payload", "target_hook") == expected_hook &&
            transition_intent_ids == receipt_intent_ids &&
            store.occurrence_for_job(job_id).nil?
          malformed! unless valid

          Hive::RefactorPatrol::ArchitectureProjectBinding.validate!(
            project: capture.project,
            source: source
          )
          immutable_json(
            "type" => "architecture_patrol_v3_job",
            "job_id" => job_id,
            "job" => aggregate,
            "job_sha256" =>
              Digest::SHA256.hexdigest(canonical(aggregate)),
            "manifest" => manifest,
            "manifest_sha256" =>
              Digest::SHA256.hexdigest(canonical(manifest)),
            "transition_intent_ids" =>
              transition_intent_ids,
            "occurrence_retired" => true
          )
        end

        def architecture_transition_intent_ids(aggregate)
          transitions = [
            aggregate.fetch("intake_transition_id")
          ]
          aggregate.fetch("attempts").each do |attempt|
            Array(attempt.fetch("transitions")).each do |transition|
              transitions << transition.fetch("intent_id")
            end
          end
          aggregate.fetch("actions").each do |action|
            action.fetch("transitions").each do |transition|
              transitions << transition.fetch("intent_id")
            end
          end
          malformed! unless transitions.uniq.length ==
                            transitions.length

          transitions.sort.freeze
        end

        def architecture_project(paths, capture:)
          {
            "name" => capture.project.fetch("name"),
            "project_id" =>
              capture.project.fetch("project_id"),
            "path" => paths.fetch(:repository),
            "hive_state_path" => paths.fetch(:hive_state),
            "repository_identity" =>
              capture.project.fetch("repository")
          }.freeze
        end

        def architecture_manifest(
          hive_state, job_id:, registration:
        )
          root = required_directory(
            hive_state, "refactor_patrol/v2/manifests"
          )
          names = exact_names!(
            root,
            /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json\z/
          )
          malformed! unless names == [ "#{job_id}.json" ]

          value = json_object(File.join(root, names.fetch(0)))
          Hive::RefactorPatrol::PrManifest.validate!(
            value,
            expected_job_id: job_id,
            registration: registration
          )
          malformed! unless
            Hive::RefactorPatrol::PrManifest.build(
              source: value.fetch("source"),
              files: value.fetch("files")
            ) == value
          value
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
          comparator:, capture:, effect_index:, repository_sha:,
          module_name:
        )
          expected = {
            "module" => module_name,
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
          repository_sha:, candidate_decisions:, module_name:,
          product_state:
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
            module_name: module_name,
            event: immutable_json(event),
            decisions: immutable_json(decisions),
            attempts: attempts,
            comparator_record: immutable_json(comparator),
            capture: immutable_json(capture.to_h),
            receipts: receipts,
            bindings: bindings,
            effect_index: immutable_json(effect_index.to_h),
            terminal_effects: terminal_effects,
            product_state: product_state,
            unverified_claims:
              immutable_json(UNVERIFIED_CLAIMS)
          ).freeze
        end

        def validate_shadow_inventory!(root)
          entries = BoundedDirectoryEntries.names(
            root,
            limit: MAX_DIRECTORY_ENTRIES
          )
          malformed! unless entries.all? do |name|
            path = File.join(root, name)
            case name
            when "patrol", "architecture-patrol"
              stat = File.lstat(path)
              safe_directory?(stat) &&
                begin
                  exact_names!(
                    path, /\A[0-9a-f]{64}\.json\z/
                  )
                  true
                end
            when "migrations"
              stat = File.lstat(path)
              safe_directory?(stat) &&
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
          json_names =
            BoundedDirectoryEntries.names(
              root,
              limit: MAX_DIRECTORY_ENTRIES
            ).select { |name| name.end_with?(".json") }
          valid = json_names.all? do |name|
            /\A(?:journal-state|recovery-index|occ-[0-9a-f]{64})\.json\z/
              .match?(name) &&
              begin
                stat = File.lstat(File.join(root, name))
                safe_regular?(stat)
              end
          end
          malformed! unless valid &&
                            json_names.include?("journal-state.json") &&
                            json_names.include?("recovery-index.json")
          json_names.freeze
        end

        def exact_names!(root, pattern)
          entries = BoundedDirectoryEntries.names(
            root,
            limit: MAX_DIRECTORY_ENTRIES
          )
          malformed! unless entries.all? do |name|
            path = File.join(root, name)
            stat = File.lstat(path)
            safe_regular?(stat) && pattern.match?(name)
          end

          entries.freeze
        end

        def canonical_object(path)
          value, bytes = json_file(path)
          malformed! unless bytes == canonical(value)

          value
        end

        def canonical_bytes(path)
          value, bytes = json_file(path)
          malformed! unless bytes == canonical(value)

          bytes
        end

        def json_object(path)
          json_file(path).fetch(0)
        end

        def json_file(path)
          before = File.lstat(path)
          malformed! unless
            safe_regular?(before) &&
              before.size <= MAX_RAW_BYTES
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          opened = File.open(path, flags)
          malformed! unless same_file?(before, opened.stat)
          bytes = opened.read(MAX_RAW_BYTES + 1)
          bytes = "".b if bytes.nil? && before.size.zero?
          malformed! unless
            bytes &&
              bytes.bytesize == before.size &&
              same_file?(before, opened.stat) &&
              same_file?(before, File.lstat(path))
          value = JSON.parse(bytes)
          malformed! unless value.is_a?(Hash)

          [ value, bytes.freeze ].freeze
        ensure
          opened&.close
        end

        def safe_directory?(stat)
          stat.directory? &&
            !stat.symlink? &&
            stat.uid == Process.euid &&
            (stat.mode & 0o022).zero?
        end

        def safe_regular?(stat)
          stat.file? &&
            !stat.symlink? &&
            stat.nlink == 1 &&
            stat.uid == Process.euid &&
            (stat.mode & 0o022).zero?
        end

        def same_file?(left, right)
          %i[
            dev ino mode nlink uid gid size mtime ctime
          ].all? do |field|
            left.public_send(field) == right.public_send(field)
          end
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
