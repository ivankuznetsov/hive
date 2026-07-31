require "hive/errors"
require "hive/modules/daemon_runtime"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_evidence_collector"
require "hive/modules/migration/qualification_scenario_input"
require "hive/modules/migration/qualification_scenario_orchestrator"

module Hive
  module Modules
    module Migration
      # Host-only projection of process custody and checkpoint snapshots into
      # the five recovery fields required by final scenario Observations.
      # Candidate Actuals cannot supply or override any of these values.
      class QualificationScenarioRecoveryEvidence
        ERROR =
          "patrol qualification recovery evidence is malformed".freeze
        SCHEMA =
          "hive-patrol-qualification-recovery-evidence".freeze
        SCHEMA_VERSION = 1
        CHECKPOINT_TRACE = {
          "after_effect_intent" =>
            [ "effect_intent", "prepared" ].freeze,
          "after_legacy_capture" =>
            [ "legacy_capture", "reserved" ].freeze,
          "after_legacy_decision" =>
            [ "legacy_decision", "projection_pending" ].freeze,
          "after_module_decision" =>
            [ "module_decision", "admitted" ].freeze,
          "before_effect_settlement" =>
            [ "effect_dispatch_uncertain", "written" ].freeze,
          "during_reconciliation" =>
            [ "effect_reconciliation", "interrupted" ].freeze,
          "reconciliation_failure" =>
            [ "reconciliation_failure", "ambiguous" ].freeze
        }.freeze
        TERMINAL_FAULT_TRACE = {
          "after_effect_intent" =>
            [ "effect_recovery", "committed" ].freeze,
          "after_legacy_capture" =>
            [ "legacy_recovery", "completed" ].freeze,
          "after_legacy_decision" =>
            [ "legacy_projection", "completed" ].freeze,
          "after_module_decision" =>
            [ "module_finalize", "succeeded" ].freeze,
          "during_reconciliation" =>
            [ "effect_recovery", "reconciled" ].freeze
        }.freeze

        Projection = Data.define(
          :case_id, :process_result_sha256, :fields
        ) do
          def to_h
            {
              "schema" =>
                QualificationScenarioRecoveryEvidence::SCHEMA,
              "schema_version" =>
                QualificationScenarioRecoveryEvidence::SCHEMA_VERSION,
              "case_id" => case_id,
              "process_result_sha256" => process_result_sha256
            }.merge(fields).freeze
          end
        end

        def call(
          result:, scenario_input:, candidate_row:,
          terminal_evidence:
        )
          unless
            result.is_a?(QualificationScenarioOrchestrator::Result) &&
              scenario_input.is_a?(QualificationScenarioInput) &&
              terminal_evidence.is_a?(
                QualificationScenarioEvidenceCollector::Projection
              )
            malformed!
          end
          candidate =
            QualificationScenarioActuals.from_h(
              "schema" => QualificationScenarioActuals::SCHEMA,
              "schema_version" =>
                QualificationScenarioActuals::SCHEMA_VERSION,
              "actuals" => [ candidate_row ]
            ).actuals.fetch(0)
          case_id = scenario_input.case_id
          fault = scenario_input.faults.fetch(0, nil)
          recovery_plan =
            fault ||
              (
                scenario_input.operation == "reconciliation_failure" ?
                  scenario_input.operation : nil
              )
          unless
            result.case_id == case_id &&
              result.recovery_plan == recovery_plan &&
              candidate.fetch("case_id") == case_id &&
              terminal_evidence.case_id == case_id &&
              terminal_evidence.module_name ==
                scenario_input.module_name
            malformed!
          end
          final_snapshot =
            result.generations.fetch(-1).after_snapshot
          pre_fault =
            if recovery_plan
              result.generations.fetch(0).after_snapshot
            else
              final_snapshot
            end
          fields = {
            "fault_checkpoint" => fault,
            "pre_fault_durable_state_sha256" =>
              pre_fault.sha256,
            "recovered_durable_state_sha256" =>
              final_snapshot.sha256,
            "recovery_trace" => recovery_trace(
              result,
              scenario_input,
              candidate
            ),
            "restart_generation" => result.generation_count
          }.freeze
          Projection.new(
            case_id: case_id.freeze,
            process_result_sha256: result.sha256,
            fields: fields
          ).freeze
        rescue Hive::ConfigError => error
          raise error if error.message == ERROR

          malformed!
        rescue ArgumentError, KeyError, NoMethodError, TypeError
          malformed!
        end

        private

        def recovery_trace(result, scenario, candidate)
          rows = result.generations.filter_map do |generation|
            evidence = generation.checkpoint_evidence
            next unless evidence

            phase, state = CHECKPOINT_TRACE.fetch(
              evidence.checkpoint
            )
            facts = evidence.facts
            trace_row(
              at: scenario.clock,
              attempt_count: facts.fetch("attempt_count"),
              decision_count: facts.fetch("decision_count"),
              phase: phase,
              state: state,
              state_sha256: evidence.state_sha256
            )
          end
          if scenario.operation == "reconciliation_failure"
            rows << terminal_trace(
              scenario,
              candidate,
              result,
              phase: "effect_recovery",
              state: "reconciled"
            )
          elsif result.recovery_plan
            phase, state =
              TERMINAL_FAULT_TRACE.fetch(result.recovery_plan)
            rows << terminal_trace(
              scenario,
              candidate,
              result,
              phase: phase,
              state: state
            )
          else
            rows.concat(
              operation_trace(result, scenario, candidate)
            )
          end
          rows.freeze
        end

        def operation_trace(result, scenario, candidate)
          final = result.generations.fetch(-1).after_snapshot.sha256
          attempts = candidate.fetch("attempts").length
          decisions = candidate.fetch("decisions").length
          operation = scenario.operation
          if %w[cooldown_retry launch_failure].include?(operation)
            times = [
              scenario.clock,
              scenario.clock +
                Hive::Modules::DaemonRuntime::RETRY_DELAY_SEC - 1,
              scenario.clock +
                Hive::Modules::DaemonRuntime::RETRY_DELAY_SEC
            ]
            return [
              trace_row(
                at: times.fetch(0),
                attempt_count: 1,
                decision_count: decisions,
                phase: "module_dispatch",
                state: "launch_failed",
                state_sha256: final
              ),
              trace_row(
                at: times.fetch(1),
                attempt_count: 1,
                decision_count: decisions,
                phase: "retry_cooldown",
                state: "deferred",
                state_sha256: final
              ),
              trace_row(
                at: times.fetch(2),
                attempt_count: 2,
                decision_count: decisions,
                phase: "retry_dispatch",
                state: "running",
                state_sha256: final
              ),
              trace_row(
                at: times.fetch(2),
                attempt_count: attempts,
                decision_count: decisions,
                phase: "module_terminal",
                state: "succeeded",
                state_sha256: final
              ),
              trace_row(
                at: times.fetch(2),
                attempt_count: attempts,
                decision_count: decisions,
                phase: "module_finalize",
                state: "succeeded",
                state_sha256: final
              )
            ].freeze
          end
          phase =
            operation == "concurrent_duplicate_delivery" ?
              "duplicate_delivery" : "module_finalize"
          [
            trace_row(
              at: scenario.clock,
              attempt_count: attempts,
              decision_count: decisions,
              phase: phase,
              state: "succeeded",
              state_sha256: final
            )
          ].freeze
        end

        def terminal_trace(
          scenario, candidate, result, phase:, state:
        )
          trace_row(
            at: scenario.clock,
            attempt_count: candidate.fetch("attempts").length,
            decision_count: candidate.fetch("decisions").length,
            phase: phase,
            state: state,
            state_sha256:
              result.generations.fetch(-1).after_snapshot.sha256
          )
        end

        def trace_row(
          at:, attempt_count:, decision_count:, phase:, state:,
          state_sha256:
        )
          {
            "at" => at.utc.iso8601(6),
            "attempt_count" => Integer(attempt_count),
            "decision_count" => Integer(decision_count),
            "phase" => phase.freeze,
            "state" => state.freeze,
            "state_sha256" => state_sha256
          }.freeze
        end

        def malformed!
          raise Hive::ConfigError, ERROR
        end
      end
    end
  end
end
