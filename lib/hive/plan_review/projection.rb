require "hive/plan_review/record"
require "hive/plan_review/store"
require "hive/canonical_json"

module Hive
  module PlanReview
    class Projection
      FRESHNESS_STATUSES = %w[current stale not_initialized invalid unknown].freeze

      attr_reader :record

      def self.load(task_folder:)
        record = Store.new(task_folder:).current_validated
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
        blocker_owner, blocker_reason = blocker_summary(record["blockers"], record)
        {
          "applicable" => true,
          "review_id" => record.review_id,
          "version" => record.version,
          "observation_digest" => observation_digest,
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
          "blocker_owner" => blocker_owner,
          "blocker_reason" => blocker_reason,
          "required_action" => record.required_action,
          "retry_at" => record["retry_at"],
          "routes" => record["routes"],
          "artifacts" => record["artifacts"],
          "freshness" => { "status" => "unknown", "reason" => nil },
          "execution_allowed" => record.execution_allowed?
        }
      end

      def self.empty_summary(state:, freshness_status:, required_action: nil,
                             blocker_owner: "none", blocker_reason: nil)
        unless Record::STATES.include?(state.to_s) && FRESHNESS_STATUSES.include?(freshness_status.to_s)
          raise ArgumentError, "invalid empty plan review summary"
        end

        {
          "applicable" => true, "review_id" => nil, "version" => nil,
          "observation_digest" => nil,
          "task_generation" => nil, "plan_digest" => nil, "policy_fingerprint" => nil,
          "computed_level" => nil, "effective_level" => nil, "state" => state.to_s,
          "outcome" => nil, "degraded" => false, "degradation_reason" => nil,
          "attempt_count" => 0, "current_attempt_id" => nil,
          "coverage_counts" => Record::COVERAGE_STATUSES.to_h { |value| [ value, 0 ] },
          "finding_counts" => empty_finding_counts,
          "blockers" => blocker_reason ? [ { "owner" => blocker_owner, "reason" => blocker_reason } ] : [],
          "blocker_owner" => blocker_owner, "blocker_reason" => blocker_reason,
          "required_action" => required_action, "retry_at" => nil,
          "routes" => [], "artifacts" => {},
          "freshness" => { "status" => freshness_status.to_s, "reason" => blocker_reason },
          "execution_allowed" => false
        }
      end

      def self.empty_finding_counts
        Finding::LIFECYCLES.to_h { |value| [ value, 0 ] }.merge(
          "total" => 0, "open_gated" => 0, "open_manual" => 0, "fyi" => 0
        )
      end
      private_class_method :empty_finding_counts

      def to_h = record.to_h

      def observation_digest
        Hive::CanonicalJSON.digest(record.to_h)
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

      def blocker_summary(blockers, review)
        first = Array(blockers).first
        owner = first.is_a?(Hash) ? first["owner"].to_s : ""
        reason = first.is_a?(Hash) ? first["reason"].to_s : first.to_s
        if owner.empty?
          owner = case review.state
          when "awaiting_decision" then "operator"
          when "retry_scheduled" then "provider"
          when "reviewing", "revising", "verifying" then "agent"
          when "blocked" then "hive"
          else "none"
          end
        end
        reason = review.required_action.to_s if reason.empty? && review.required_action
        [ owner, reason.empty? ? nil : reason ]
      end
    end
  end
end
