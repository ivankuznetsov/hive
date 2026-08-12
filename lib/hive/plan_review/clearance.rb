require "hive/plan_review/coverage_evaluator"
require "hive/plan_review/finding"

module Hive
  module PlanReview
    module Clearance
      Result = Data.define(
        :state, :outcome, :execution_allowed, :blockers, :required_action,
        :degradation_reason
      )

      module_function

      def evaluate(level:, coverage:, findings:, adapter_outcomes:, verification_outcome:,
                   revision_required:, revision_complete:, verification_complete:,
                   verification_blockers: [])
        typed = Array(findings).map { |entry| entry.is_a?(Finding) ? entry : Finding.new(entry) }
        decision_findings = typed.select do |finding|
          %w[gated_auto manual].include?(finding.classification) &&
            !%w[approved answered incorporated verified resolved waived].include?(finding.lifecycle)
        end
        unless decision_findings.empty?
          return build(
            "awaiting_decision", nil, false,
            decision_findings.map { |finding| finding_blocker(finding) },
            action_for(decision_findings.first), nil
          )
        end

        accepted = typed.select do |finding|
          finding.classification == "safe_auto" ||
            %w[approved answered].include?(finding.lifecycle)
        end
        needs_revision = revision_required || !accepted.empty?
        if needs_revision && !revision_complete
          return build("revising", nil, false, [], "revise plan with accepted findings", nil)
        end
        unless verification_complete
          return build("verifying", nil, false, [], "run disposition verification", nil)
        end

        unless verification_blockers.empty?
          return build(
            "blocked", "blocked", false, Array(verification_blockers),
            "resolve verification blockers with a new linked plan", nil
          )
        end

        coverage_result = CoverageEvaluator.evaluate(
          level:, coverage:, adapter_outcomes:, verification_outcome:
        )
        if coverage_result.blocked?
          return build(
            "blocked", "blocked", false, coverage_result.blockers,
            "waive named coverage or restore required reviewer capability", nil
          )
        end
        if coverage_result.degraded?
          return build(
            "degraded_cleared", "degraded_cleared", true, [], nil,
            coverage_result.degradation_reason
          )
        end

        build("cleared", "cleared", true, [], nil, nil)
      end

      def finding_blocker(finding)
        {
          "owner" => "operator",
          "reason" => finding.classification == "manual" ? "manual_answer_required" : "gated_approval_required",
          "finding_fingerprint" => finding.fingerprint
        }.freeze
      end
      private_class_method :finding_blocker

      def action_for(finding)
        finding.classification == "manual" ?
          "answer manual plan finding #{finding.fingerprint}" :
          "approve gated plan finding #{finding.fingerprint}"
      end
      private_class_method :action_for

      def build(state, outcome, execution_allowed, blockers, action, degradation)
        Result.new(
          state:, outcome:, execution_allowed:, blockers: blockers.freeze,
          required_action: action, degradation_reason: degradation
        ).freeze
      end
      private_class_method :build
    end
  end
end
