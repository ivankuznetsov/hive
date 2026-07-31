require "hive/errors"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_observations"

module Hive
  module Modules
    module Migration
      # Trusted host-only binder. Candidate processes emit unlabelled actuals;
      # this oracle matches each one to one descriptor decision, checks the
      # control against raw capture evidence, then attaches qualification
      # identity and decision classification.
      class QualificationScenarioOracle
        def call(descriptor:, lane:, actuals:)
          unless
            descriptor.is_a?(QualificationRunDescriptor) &&
              QualificationRunDescriptor::LANES.include?(
                lane.to_s
              ) &&
              actuals.is_a?(Array) &&
              !actuals.empty? &&
              actuals.all? do |value|
                value.is_a?(QualificationScenarioActuals)
              end
            malformed!
          end
          expected = expected_decisions(descriptor)
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
            row.merge(
              "decision_class" =>
                expectation.fetch("decision_class")
            )
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

        def expected_decisions(descriptor)
          descriptor.scenarios.fetch("cases").flat_map do |row|
            row.fetch("decision_expectations").map do |decision|
              [
                [
                  row.fetch("case_id"),
                  decision.fetch("decision_id")
                ],
                decision
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
            rationale == "not_due" &&
              outcome["findings"].to_i.zero? &&
              outcome["action_count"].to_i.zero?
          when "none"
            true
          else
            false
          end
          malformed! unless valid
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification scenario actuals do not match descriptor"
        end
      end
    end
  end
end
