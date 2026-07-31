require "hive/errors"
require "hive/modules/daemon_runtime"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_observations"
require "hive/modules/migration/qualification_scenario_recovery_evidence"

module Hive
  module Modules
    module Migration
      # Trusted host-only binder. Candidate processes emit unlabelled actuals;
      # this oracle matches each one to one descriptor decision, checks the
      # control against raw capture evidence, then attaches qualification
      # identity and decision classification.
      class QualificationScenarioOracle
        def call(
          descriptor:, lane:, actuals:, recovery_evidence:
        )
          unless
            descriptor.is_a?(QualificationRunDescriptor) &&
              QualificationRunDescriptor::LANES.include?(
                lane.to_s
              ) &&
              actuals.is_a?(Array) &&
              !actuals.empty? &&
              actuals.all? do |value|
                value.is_a?(QualificationScenarioActuals)
              end &&
              recovery_evidence.is_a?(Array) &&
              recovery_evidence.all? do |value|
                value.is_a?(
                  QualificationScenarioRecoveryEvidence::Projection
                )
              end
            malformed!
          end
          expected = expected_decisions(descriptor)
          recovery = recovery_by_case(
            descriptor,
            recovery_evidence
          )
          rows = actuals.flat_map(&:actuals)
          actual_keys = rows.map do |row|
            [
              row.fetch("case_id"),
              row.fetch("decision_id")
            ]
          end
          malformed! unless
            actual_keys.uniq.length == actual_keys.length &&
              actual_keys.sort == expected.keys.sort
          observations = rows.map do |row|
            key = [
              row.fetch("case_id"),
              row.fetch("decision_id")
            ]
            expectation = expected.fetch(key)
            verify_identity!(row, expectation)
            verify_control!(row, expectation)
            observation = row.merge(
              "decision_class" =>
                expectation.fetch("decision_class")
            ).merge(
              recovery.fetch(row.fetch("case_id")).fields
            )
            verify_recovery_trace!(observation, expectation)
            observation
          end.sort_by do |row|
            [
              row.fetch("case_id"),
              row.fetch("decision_id")
            ]
          end
          QualificationScenarioObservations.from_h(
            "schema" =>
              QualificationScenarioObservations::SCHEMA,
            "schema_version" =>
              QualificationScenarioObservations::SCHEMA_VERSION,
            "run_id" => descriptor.run_id,
            "lane" => lane.to_s,
            "scenario_manifest_sha256" =>
              descriptor.scenarios.fetch("manifest_sha256"),
            "observations" => observations
          )
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end

        private

        def recovery_by_case(descriptor, values)
          expected = descriptor.scenarios.fetch("cases").map do |row|
            row.fetch("case_id")
          end.sort
          actual = values.map(&:case_id)
          malformed! unless
            actual.uniq.length == actual.length &&
              actual.sort == expected
          values.to_h do |value|
            fields = value.fields
            malformed! unless
              fields.is_a?(Hash) &&
                fields.keys.sort ==
                  QualificationScenarioObservations::
                    HOST_RECOVERY_KEYS.sort
            [ value.case_id, value ]
          end.freeze
        end

        def expected_decisions(descriptor)
          descriptor.scenarios.fetch("cases").flat_map do |row|
            row.fetch("decision_expectations").map do |decision|
              [
                [
                  row.fetch("case_id"),
                  decision.fetch("decision_id")
                ],
                decision.merge(
                  "_faults" => row.fetch("faults")
                )
              ]
            end
          end.to_h
        end

        def verify_identity!(row, expected)
          %w[
            module repository_sha trigger_digest
          ].each do |key|
            malformed! unless
              row.fetch(key) == expected.fetch(key)
          end
        end

        def verify_control!(row, expected)
          capture = row.dig(
            "event",
            "payload",
            "legacy_mutator_capture"
          )
          malformed! unless capture.is_a?(Hash)
          rationale = capture.dig("selection", "rationale")
          outcome = capture["outcome"]
          malformed! unless outcome.is_a?(Hash)
          valid = case expected.fetch("control")
          when "ordinary_positive_finding"
            row["module"] == "patrol" &&
              rationale == "due" &&
              outcome["findings"].to_i.positive? &&
              Array(outcome["finding_ids"]).any?
          when "architecture_positive_thesis"
            row["module"] == "architecture-patrol" &&
              rationale == "due" &&
              outcome["action_count"].to_i.positive? &&
              !outcome["job_id"].to_s.empty?
          when "clean_negative"
            clean_negative?(
              row.fetch("module"),
              rationale: rationale,
              outcome: outcome
            )
          when "none"
            true
          else
            false
          end
          malformed! unless valid
        end

        def clean_negative?(module_name, rationale:, outcome:)
          return (
            rationale == "due" &&
              outcome["review_complete"] == true &&
              outcome["features_reviewed"].to_i.positive? &&
              outcome["findings"].to_i.zero? &&
              Array(outcome["finding_ids"]).empty?
          ) if module_name == "patrol"

          module_name == "architecture-patrol" &&
            rationale == "due" &&
            outcome["complete"] == true &&
            outcome["action_count"].to_i.zero? &&
            outcome["zero_reason"] == "no_theses"
        end

        def verify_recovery_trace!(row, expectation)
          trace = row.fetch("recovery_trace")
          phases = trace.map { |entry| entry.fetch("phase") }
          decision_class =
            expectation.fetch("decision_class")
          valid = case decision_class
          when "concurrent_duplicate_delivery"
            phases.include?("duplicate_delivery") &&
              row.fetch("attempts").length == 1
          when "cooldown_retry", "launch_failure"
            trace_matches_launch_retry?(trace, phases)
          when "reconciliation_failure"
            phases.first(3) == %w[
              effect_dispatch_uncertain reconciliation_failure
              effect_recovery
            ] &&
              row.fetch("restart_generation") >= 3
          else
            true
          end
          faults = expectation.fetch("_faults")
          valid &&=
            faults.empty? ?
              row["fault_checkpoint"].nil? :
              faults == [ row["fault_checkpoint"] ] &&
                trace_matches_fault?(
                  faults.fetch(0),
                  phases,
                  row
                )
          malformed! unless valid
        end

        def trace_matches_fault?(fault, phases, row)
          required = {
            "after_effect_intent" =>
              %w[effect_intent effect_recovery],
            "after_legacy_capture" =>
              %w[legacy_capture legacy_recovery],
            "after_legacy_decision" =>
              %w[legacy_decision legacy_projection],
            "after_module_decision" =>
              %w[module_decision],
            "during_reconciliation" =>
              %w[
                effect_dispatch_uncertain effect_reconciliation
                effect_recovery
              ]
          }.fetch(fault, [])
          required_generation =
            fault == "during_reconciliation" ? 3 : 2
          !required.empty? &&
            phases.first(required.length) == required &&
            row.fetch("restart_generation") >=
              required_generation
        rescue KeyError
          false
        end

        def trace_matches_launch_retry?(trace, phases)
          return false unless phases == %w[
            module_dispatch retry_cooldown retry_dispatch
            module_terminal module_finalize
          ]

          started_at = Time.iso8601(
            trace.fetch(0).fetch("at")
          )
          deferred_at = Time.iso8601(
            trace.fetch(1).fetch("at")
          )
          retried_at = Time.iso8601(
            trace.fetch(2).fetch("at")
          )
          deferred_at - started_at ==
            Hive::Modules::DaemonRuntime::RETRY_DELAY_SEC - 1 &&
            retried_at - deferred_at == 1 &&
            trace.fetch(1).fetch("attempt_count") == 1 &&
            trace.fetch(2).fetch("attempt_count") == 2
        rescue ArgumentError, KeyError
          false
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification scenario actuals do not match descriptor"
        end
      end
    end
  end
end
