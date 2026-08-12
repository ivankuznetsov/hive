require "hive/plan_review/record"
require "hive/plan_review/store"
require "hive/plan_review/identity"
require "digest"
require "json"

module Hive
  module PlanReview
    class Projection
      attr_reader :record

      def self.load(task_folder:)
        record = Store.new(task_folder:).current
        new(record)
      end

      def initialize(record)
        @record = record.is_a?(Record) ? record : Record.new(record)
        raise InvalidRecord, "plan review projection requires a projection record" unless @record.kind == "projection"

        freeze
      end

      def fresh?(task_generation:, plan_digest:, policy_fingerprint:)
        record.task_generation == task_generation &&
          record.plan_digest == plan_digest &&
          record.policy_fingerprint == policy_fingerprint
      end

      def execution_allowed?(task_generation:, plan_digest:, policy_fingerprint:)
        record.execution_allowed? && fresh?(task_generation:, plan_digest:, policy_fingerprint:)
      end

      def summary
        findings = record["findings"].map { |entry| Finding.new(entry) }
        coverage = record["coverage"]
        {
          "applicable" => true,
          "review_id" => record.review_id,
          "version" => record.version,
          "task_generation" => record.task_generation,
          "plan_digest" => record.plan_digest,
          "policy_fingerprint" => record.policy_fingerprint,
          "computed_level" => record.computed_level,
          "effective_level" => record.effective_level,
          "state" => record.state,
          "outcome" => record.outcome,
          "degraded" => record.state == "degraded_cleared",
          "degradation_reason" => record["degradation_reason"],
          "attempt_count" => record["attempt_ids"].length,
          "current_attempt_id" => record["current_attempt_id"],
          "coverage_counts" => count_by(coverage, "status", Record::COVERAGE_STATUSES),
          "finding_counts" => finding_counts(findings),
          "blockers" => record["blockers"],
          "required_action" => record.required_action,
          "routes" => record["routes"],
          "artifacts" => record["artifacts"],
          "execution_allowed" => record.execution_allowed?
        }
      end

      def to_h = record.to_h

      def observation_digest
        Digest::SHA256.hexdigest(JSON.generate(Identity.normalize(record.to_h)))
      end

      private

      def count_by(entries, key, vocabulary)
        vocabulary.to_h { |value| [ value, entries.count { |entry| entry[key] == value } ] }
      end

      def finding_counts(findings)
        lifecycle = Finding::LIFECYCLES.to_h do |value|
          [ value, findings.count { |finding| finding.lifecycle == value } ]
        end
        lifecycle.merge(
          "total" => findings.length,
          "open_gated" => findings.count do |finding|
            finding.classification == "gated_auto" && !finding.resolved?
          end,
          "open_manual" => findings.count do |finding|
            finding.classification == "manual" && !finding.resolved?
          end,
          "fyi" => findings.count { |finding| finding.classification == "fyi" }
        )
      end
    end
  end
end
