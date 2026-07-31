require "digest"
require "json"
require "time"
require "hive/attempts/record"
require "hive/errors"
require "hive/modules/decision_journal"
require "hive/modules/event_ledger"
require "hive/modules/hook_attempt"
require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Canonical driver-produced links from a qualification scenario to the
      # production EventLedger, DecisionJournal, Attempts, comparator, capture,
      # and effect identities it actually observed. The top-level decision_id
      # is the comparator/descriptor decision identity; decision.decision_id is
      # the distinct DecisionJournal identity. Fault, durable-state, and
      # restart-generation values remain driver observations; callers must
      # additionally bind each row to descriptor cases and immutable
      # comparator/effect records.
      class QualificationScenarioObservations
        SCHEMA =
          "hive-patrol-qualification-scenario-observations".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 8 * 1024 * 1024
        MAX_OBSERVATIONS = 512
        MAX_EVENT_BYTES = 128 * 1024
        MAX_DECISION_BYTES = 64 * 1024
        MAX_DECISIONS_PER_OBSERVATION = 16
        MAX_ATTEMPT_BYTES = 128 * 1024
        MAX_ATTEMPTS_PER_OBSERVATION = 16
        MAX_RECOVERY_TRACE_ENTRIES = 32
        TOP_LEVEL_KEYS = %w[
          lane observations run_id scenario_manifest_sha256 schema
          schema_version
        ].freeze
        OBSERVATION_KEYS = %w[
          attempts case_id comparator_semantic_digest decisions
          decision_class decision_id event event_id fault_checkpoint
          legacy_capture_id legacy_effect_keys module module_effect_keys
          pre_fault_durable_state_sha256 recovered_durable_state_sha256
          recovery_trace repository_sha restart_generation trigger_digest
        ].freeze
        EVENT_KEYS = %w[
          event_id event_name idempotency_key occurred_at payload project
          project_id recorded_at schema schema_version source
        ].freeze
        DECISION_KEYS = %w[
          artifacts attempt_id binding_digest concurrency
          configuration_digest cursor_after cursor_before decision_id
          evaluated_at event_id event_name grant_digest hook module
          module_generation outcome project project_id reason retry schema
          schema_version task_id
        ].freeze
        ATTEMPT_KEYS = %w[
          attempt_id loss outcome ownership_generation predecessor_attempt_id
          projection_sha256 receipt receipt_sha256 retry_charge state subject
          task_generation task_input_epoch
        ].freeze
        SUBJECT_KEYS = %w[
          configuration_digest event_id event_name grant_digest hook kind
          module module_generation occurrence_id project_id
        ].freeze
        RECEIPT_KEYS = %w[
          attempt_id ended_at exit_status final_checkpoint log_reference
          outcome output_references ownership_generation started_at
          task_generation task_input_epoch
        ].freeze
        LOSS_KEYS = %w[at reason].freeze
        RECOVERY_TRACE_KEYS = %w[
          at attempt_count decision_count phase state state_sha256
        ].freeze
        SOURCE_KEYS = %w[id type].freeze
        UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
        DECISION_ID = /\Adec-[0-9a-f]{64}\z/
        EVENT_ID = /\Aevt-[0-9a-f]{64}\z/
        CAPTURE_ID = /\Acap-[0-9a-f]{64}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        SHA = /\A[0-9a-f]{40}\z/
        EFFECT = /\Aeffect-[0-9a-f]{64}\z/
        OWNERSHIP_GENERATION = /\A[1-9][0-9]*:[0-9a-f]{40}\z/

        attr_reader :payload

        class << self
          def load(bytes)
            malformed! unless bytes.is_a?(String) &&
                              bytes.bytesize <= MAX_BYTES
            value = JSON.parse(bytes)
            malformed! unless bytes == canonical(value)
            new(validate(value))
          rescue JSON::ParserError, EncodingError
            malformed!
          end

          def from_h(value)
            immutable = immutable(value)
            new(validate(immutable))
          end

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          private

          def validate(value)
            exact!(value, TOP_LEVEL_KEYS)
            malformed! unless value["schema"] == SCHEMA &&
                              value["schema_version"] == SCHEMA_VERSION &&
                              QualificationRunDescriptor::RUN_ID.match?(
                                value["run_id"].to_s
                              ) &&
                              QualificationRunDescriptor::LANES.include?(
                                value["lane"].to_s
                              ) &&
                              DIGEST.match?(
                                value["scenario_manifest_sha256"].to_s
                              )
            rows = value["observations"]
            malformed! unless rows.is_a?(Array) && !rows.empty? &&
                              rows.length <= MAX_OBSERVATIONS
            normalized = rows.map { |row| observation(row) }
            keys = normalized.map do |row|
              [ row.fetch("case_id"), row.fetch("decision_id") ]
            end
            decision_ids = normalized.map do |row|
              row.fetch("decision_id")
            end
            malformed! unless
              decision_ids.uniq.length == decision_ids.length &&
              keys.uniq.length == keys.length &&
                              keys == keys.sort
            immutable(value.merge("observations" => normalized))
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          def observation(value)
            exact!(value, OBSERVATION_KEYS)
            case_id = value["case_id"].to_s
            malformed! unless
              QualificationRunDescriptor::SAFE_ID.match?(case_id) &&
              DIGEST.match?(value["decision_id"].to_s) &&
              QualificationRunDescriptor::MODULES.include?(
                value["module"].to_s
              ) &&
              nonempty?(value["decision_class"]) &&
              SHA.match?(value["repository_sha"].to_s) &&
              DIGEST.match?(value["trigger_digest"].to_s) &&
              DIGEST.match?(
                value["comparator_semantic_digest"].to_s
              ) &&
              CAPTURE_ID.match?(value["legacy_capture_id"].to_s) &&
              EVENT_ID.match?(value["event_id"].to_s) &&
              DIGEST.match?(
                value["pre_fault_durable_state_sha256"].to_s
              ) &&
              DIGEST.match?(
                value["recovered_durable_state_sha256"].to_s
              ) &&
              positive_integer?(value["restart_generation"])
            effect_keys!(
              value["legacy_effect_keys"],
              empty: true
            )
            effect_keys!(value["module_effect_keys"], empty: true)
            fault = value["fault_checkpoint"]
            malformed! unless fault.nil? ||
                              QualificationRunDescriptor::REQUIRED_FAULTS
                                .include?(fault)

            capture = event!(
              value.fetch("event"),
              module_name: value.fetch("module")
            )
            malformed! unless
              value["event_id"] == value.dig("event", "event_id") &&
              value["legacy_capture_id"] == capture.capture_id
            decisions = decisions!(
              value.fetch("decisions"),
              event: value.fetch("event"),
              module_name: value.fetch("module")
            )
            attempts!(
              value.fetch("attempts"),
              event: value.fetch("event"),
              decisions: decisions
            )
            recovery_trace!(value.fetch("recovery_trace"))
            immutable(value)
          end

          def recovery_trace!(value)
            malformed! unless
              value.is_a?(Array) &&
                !value.empty? &&
                value.length <= MAX_RECOVERY_TRACE_ENTRIES
            rows = value.map do |row|
              exact!(row, RECOVERY_TRACE_KEYS)
              malformed! unless
                exact_timestamp?(row["at"]) &&
                  safe_trace_token?(row["phase"]) &&
                  safe_trace_token?(row["state"]) &&
                  DIGEST.match?(row["state_sha256"].to_s) &&
                  nonnegative_integer?(row["attempt_count"]) &&
                  nonnegative_integer?(row["decision_count"])
              row
            end
            malformed! unless
              rows.map { |row| row.fetch("at") } ==
                rows.map { |row| row.fetch("at") }.sort
            rows.freeze
          end

          def safe_trace_token?(value)
            value.is_a?(String) &&
              QualificationRunDescriptor::SAFE_ID.match?(value)
          end

          def nonnegative_integer?(value)
            value.is_a?(Integer) && value >= 0
          end

          def event!(value, module_name:)
            exact!(value, EVENT_KEYS)
            bounded!(value, MAX_EVENT_BYTES)
            malformed! unless
              value["schema"] == EventLedger::SCHEMA &&
              value["schema_version"] == EventLedger::SCHEMA_VERSION &&
              value["event_name"] == "schedule" &&
              EVENT_ID.match?(value["event_id"].to_s) &&
              nonempty?(value["project_id"]) &&
              nonempty?(value["project"]) &&
              exact_timestamp?(value["occurred_at"]) &&
              exact_timestamp?(value["recorded_at"]) &&
              nonempty?(value["idempotency_key"]) &&
              value["idempotency_key"].bytesize <= 512
            exact!(value["source"], SOURCE_KEYS)
            payload = value["payload"]
            payload_keys = %w[
              due_at legacy_mutator_capture missed_windows schedule
              target_module
            ]
            payload_keys << "target_hook" if
              module_name == "architecture-patrol"
            exact!(payload, payload_keys)
            malformed! unless
              payload["target_module"] == module_name &&
              nonempty?(payload["schedule"]) &&
              exact_timestamp?(payload["due_at"]) &&
              payload["missed_windows"].is_a?(Integer) &&
              payload["missed_windows"] >= 0
            malformed! if
              module_name == "architecture-patrol" &&
              !nonempty?(payload["target_hook"])
            capture = PatrolCapture.from_h(
              payload.fetch("legacy_mutator_capture")
            )
            source_type = module_name == "patrol" ?
              "legacy_patrol_completion" :
              "legacy_architecture_patrol_completion"
            idempotency_prefix = module_name == "patrol" ?
              "patrol-finalized:" :
              "architecture-patrol-finalized:"
            malformed! unless
              capture.module_name == module_name &&
              capture.project.fetch("project_id") ==
                value["project_id"] &&
              capture.project.fetch("name") == value["project"] &&
              value["source"] == {
                "type" => source_type,
                "id" => capture.occurrence_id
              } &&
              value["idempotency_key"] ==
                "#{idempotency_prefix}#{capture.occurrence_id}" &&
              value["occurred_at"] == capture.occurred_at &&
              payload["due_at"] == capture.occurred_at
            expected_id = "evt-#{Digest::SHA256.hexdigest(
              [
                value["project_id"],
                value["event_name"],
                value["idempotency_key"]
              ].join("\0")
            )}"
            malformed! unless value["event_id"] == expected_id
            capture
          rescue Hive::ConfigError
            malformed!
          end

          def decisions!(value, event:, module_name:)
            malformed! unless
              value.is_a?(Array) &&
                !value.empty? &&
                value.length <= MAX_DECISIONS_PER_OBSERVATION
            rows = value.map do |decision|
              decision!(
                decision,
                event: event,
                module_name: module_name
              )
            end
            malformed! unless
              rows.map { |row| row.fetch("decision_id") }.uniq.length ==
                rows.length &&
                rows.map { |row| row.fetch("evaluated_at") } ==
                  rows.map { |row| row.fetch("evaluated_at") }.sort &&
                primary_decisions(rows).length == 1
            rows.freeze
          end

          def primary_decisions(rows)
            rows.select do |row|
              (
                row["outcome"] == "launch" &&
                row["reason"] == "admitted"
              ) ||
                (
                  row["outcome"] == "skip" &&
                  row["reason"] == "launch_handoff_failed"
                )
            end
          end

          def decision!(value, event:, module_name:)
            exact!(value, DECISION_KEYS)
            bounded!(value, MAX_DECISION_BYTES)
            malformed! unless
              value["schema"] == DecisionJournal::SCHEMA &&
              value["schema_version"] == DecisionJournal::SCHEMA_VERSION &&
              DECISION_ID.match?(value["decision_id"].to_s) &&
              value["project_id"] == event["project_id"] &&
              value["project"] == event["project"] &&
              value["module"] == module_name &&
              nonempty?(value["hook"]) &&
              value["event_id"] == event["event_id"] &&
              value["event_name"] == event["event_name"] &&
              exact_timestamp?(value["evaluated_at"]) &&
              DecisionJournal::OUTCOMES.include?(value["outcome"]) &&
              DecisionJournal::REASONS.include?(value["reason"]) &&
              value["task_id"].nil? &&
              value["artifacts"] == [] &&
              value["retry"].nil?
            %w[
              binding_digest configuration_digest grant_digest
            ].each do |key|
              malformed! unless value[key].nil? ||
                                DIGEST.match?(value[key].to_s)
            end
            %w[cursor_before cursor_after module_generation].each do |key|
              malformed! unless value[key].nil? ||
                                nonempty?(value[key])
            end
            malformed! unless
              value["concurrency"].nil? ||
              %w[allow drop replace].include?(value["concurrency"])
            attempt_id = value["attempt_id"]
            linked_reason = %w[
              admitted launch_handoff_failed terminal_replay
            ].include?(value["reason"])
            duplicate = value["reason"] == "duplicate"
            malformed! unless
              (
                linked_reason == !attempt_id.nil? ||
                (
                  duplicate &&
                  (
                    attempt_id.nil? ||
                    UUID.match?(attempt_id.to_s)
                  )
                )
              ) &&
                (
                  attempt_id.nil? ||
                  UUID.match?(attempt_id.to_s)
                ) &&
                (
                  value["outcome"] == "skip" ||
                  (
                    value["outcome"] == "launch" &&
                    value["reason"] == "admitted"
                  )
                )
            expected_hook =
              event.dig("payload", "target_hook") ||
              "scheduled-scan"
            malformed! unless value["hook"] == expected_hook
            immutable(value)
          end

          def attempts!(value, event:, decisions:)
            malformed! unless value.is_a?(Array) &&
                              !value.empty? &&
                              value.length <=
                                MAX_ATTEMPTS_PER_OBSERVATION
            primary_decision =
              primary_decisions(decisions).fetch(0)
            rows = value.map do |attempt|
              attempt!(
                attempt,
                event: event,
                decision: primary_decision
              )
            end
            malformed! unless
              rows.first["attempt_id"] ==
                primary_decision["attempt_id"] &&
              rows.first["predecessor_attempt_id"].nil? &&
              rows.first["retry_charge"] == 0
            malformed! unless
              rows.map { |row| row["attempt_id"] }.uniq.length ==
                rows.length
            rows.each_cons(2) do |previous, current|
              malformed! unless
                current["predecessor_attempt_id"] ==
                  previous["attempt_id"] &&
                current["retry_charge"] ==
                  previous["retry_charge"] + 1
            end
            malformed! unless
              rows[0...-1].all? do |row|
                row["state"] == "lost" ||
                  (
                    row["state"] == "terminal" &&
                    row["outcome"] != "succeeded"
                  )
              end &&
                rows.last["state"] == "terminal" &&
                rows.last["outcome"] == "succeeded"
            base_generation =
              Hive::Modules::HookAttempt.run_id_for(
                rows.first.fetch("subject")
              )
            rows.each do |row|
              charge = row.fetch("retry_charge")
              expected_generation = if charge.zero?
                base_generation
              else
                Digest::SHA256.hexdigest(
                  [
                    "hive-module-hook-retry-v1",
                    base_generation,
                    charge
                  ].join("\0")
                )
              end
              malformed! unless
                row["task_generation"] == expected_generation
            end
          rescue IndexError
            malformed!
          end

          def attempt!(value, event:, decision:)
            exact!(value, ATTEMPT_KEYS)
            bounded!(value, MAX_ATTEMPT_BYTES)
            malformed! unless
              UUID.match?(value["attempt_id"].to_s) &&
              (
                value["predecessor_attempt_id"].nil? ||
                UUID.match?(
                  value["predecessor_attempt_id"].to_s
                )
              ) &&
              value["retry_charge"].is_a?(Integer) &&
              value["retry_charge"].between?(
                0, MAX_ATTEMPTS_PER_OBSERVATION - 1
              ) &&
              %w[lost terminal].include?(value["state"]) &&
              DIGEST.match?(value["task_generation"].to_s) &&
              OWNERSHIP_GENERATION.match?(
                value["ownership_generation"].to_s
              ) &&
              positive_integer?(value["task_input_epoch"])
            subject!(
              value.fetch("subject"),
              event: event,
              decision: decision
            )
            validate_attempt_outcome!(value)
            expected_projection = Digest::SHA256.hexdigest(
              canonical(
                value.reject do |key, _child|
                  key == "projection_sha256"
                end
              )
            )
            malformed! unless
              value["projection_sha256"] == expected_projection
            immutable(value)
          end

          def subject!(value, event:, decision:)
            exact!(value, SUBJECT_KEYS)
            malformed! unless
              value["kind"] == "module_hook" &&
              value["project_id"] == event["project_id"] &&
              value["module"] == decision["module"] &&
              value["hook"] == decision["hook"] &&
              value["event_id"] == event["event_id"] &&
              value["occurrence_id"] == event["event_id"] &&
              value["event_name"] == event["event_name"] &&
              value["module_generation"] ==
                decision["module_generation"] &&
              value["configuration_digest"] ==
                decision["configuration_digest"] &&
              value["grant_digest"] == decision["grant_digest"] &&
              SHA.match?(value["module_generation"].to_s) &&
              DIGEST.match?(
                value["configuration_digest"].to_s
              ) &&
              DIGEST.match?(value["grant_digest"].to_s)
          end

          def validate_attempt_outcome!(value)
            if value["state"] == "terminal"
              malformed! unless
                Hive::Attempts::Record::TERMINAL_OUTCOMES
                  .include?(value["outcome"]) &&
                value["loss"].nil? &&
                value["receipt"].is_a?(Hash)
              exact!(value["receipt"], RECEIPT_KEYS)
              Hive::Attempts::Record.validate_receipt!(
                value["receipt"],
                attempt_id: value["attempt_id"],
                task_generation: value["task_generation"],
                task_input_epoch: value["task_input_epoch"],
                ownership_generation:
                  value["ownership_generation"]
              )
              expected = Digest::SHA256.hexdigest(
                canonical(value["receipt"])
              )
              malformed! unless value["receipt_sha256"] == expected
            else
              exact!(value["loss"], LOSS_KEYS)
              malformed! unless value["outcome"].nil? &&
                                value["receipt"].nil? &&
                                value["receipt_sha256"].nil? &&
                                nonempty?(value.dig("loss", "reason")) &&
                                exact_timestamp?(
                                  value.dig("loss", "at")
                                )
            end
          rescue Hive::Attempts::InvalidReceipt
            malformed!
          end

          def effect_keys!(value, empty: false)
            malformed! unless
              value.is_a?(Array) &&
              (empty || !value.empty?) &&
              value.uniq.length == value.length &&
              value == value.sort &&
              value.all? { |key| EFFECT.match?(key.to_s) }
          end

          def exact!(value, keys)
            malformed! unless value.is_a?(Hash) &&
                              value.keys.sort == keys.sort
          end

          def bounded!(value, maximum)
            malformed! if canonical(value).bytesize > maximum
          end

          def nonempty?(value)
            value.is_a?(String) && !value.empty? &&
              value.bytesize <= 512 &&
              !value.match?(/[\u0000-\u001f\u007f]/)
          end

          def positive_integer?(value)
            value.is_a?(Integer) && value.positive?
          end

          def exact_timestamp?(value)
            return false unless value.is_a?(String)

            time = Time.iso8601(value)
            value == time.utc.iso8601(6)
          rescue ArgumentError
            false
          end

          def immutable(value)
            case value
            when Hash
              value.to_h do |key, child|
                [ key.to_s.dup.freeze, immutable(child) ]
              end.freeze
            when Array
              value.map { |child| immutable(child) }.freeze
            when String
              value.dup.freeze
            when Integer, TrueClass, FalseClass, NilClass
              value
            else
              malformed!
            end
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol qualification scenario observations are malformed"
          end
        end

        def initialize(payload)
          @payload = payload
          freeze
        end

        def to_h = payload
        def run_id = payload.fetch("run_id")
        def lane = payload.fetch("lane")
        def scenario_manifest_sha256 =
          payload.fetch("scenario_manifest_sha256")
        def observations = payload.fetch("observations")
      end
    end
  end
end
