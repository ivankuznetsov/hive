require "hive/patrol/fingerprint"

module Hive
  module RefactorPatrol
    FINDING_ROUTES = %w[fix discuss dismiss].freeze
    FINDING_DISMISS_FLAGS = %w[
      boundary_override_attempt collision_already_seen collision_dismissed
      collision_patrol_pr collision_similar_known inadmissible
      invalid_architecture_effect invalid_route unverified_evidence
    ].freeze
    Thesis = Struct.new(
      :id, :feature_id, :feature, :problem, :cost, :evidence,
      :proposed_refactor, :feature_boundary, :architecture_effects, :route,
      :confidence, :risk, :required_validation, :admissible,
      :admissibility_reason, :follow_up_approval_state, :fingerprint,
      :collision,
      keyword_init: true
    ) do
      def to_h
        {
          "id" => id,
          "feature_id" => feature_id,
          "feature" => feature,
          "problem" => problem,
          "cost" => cost,
          "evidence" => Array(evidence),
          "proposed_refactor" => proposed_refactor,
          "feature_boundary" => feature_boundary || {},
          "architecture_effects" => Array(architecture_effects),
          "route" => route,
          "confidence" => confidence,
          "risk" => risk || {},
          "required_validation" => required_validation || {},
          "admissible" => admissible,
          "admissibility_reason" => admissibility_reason.to_s,
          "follow_up_approval_state" => follow_up_approval_state || "pending",
          "fingerprint" => fingerprint,
          "collision" => collision
        }.compact
      end

      def self.from_h(hash)
        new(
          id: hash.fetch("id"),
          feature_id: hash.fetch("feature_id"),
          feature: hash.fetch("feature"),
          problem: hash.fetch("problem"),
          cost: hash.fetch("cost"),
          evidence: Array(hash["evidence"]),
          proposed_refactor: hash.fetch("proposed_refactor"),
          feature_boundary: hash.fetch("feature_boundary"),
          architecture_effects: Array(hash.fetch("architecture_effects")),
          route: hash.fetch("route"),
          confidence: hash.fetch("confidence"),
          risk: hash.fetch("risk"),
          required_validation: hash.fetch("required_validation"),
          admissible: hash.fetch("admissible"),
          admissibility_reason: hash.fetch("admissibility_reason"),
          follow_up_approval_state: hash.fetch("follow_up_approval_state"),
          fingerprint: hash.fetch("fingerprint"),
          collision: hash["collision"]
        )
      end

      def effective_route(min_confidence: "medium")
        return "dismiss" unless admissible == true
        return "dismiss" if confidence_below?(min_confidence)

        flags = Array(risk && risk["flags"]).map(&:to_s)
        return "dismiss" if (flags & FINDING_DISMISS_FLAGS).any?

        requested = FINDING_ROUTES.include?(route.to_s) ? route.to_s : "dismiss"
        return "dismiss" if requested == "dismiss"
        return "discuss" if flags.any?

        requested
      end

      def route_reasons(min_confidence: "medium")
        reasons = Array(risk && risk["flags"]).map(&:to_s).reject(&:empty?)
        reasons << admissibility_reason.to_s unless admissible == true || admissibility_reason.to_s.empty?
        reasons << "inadmissible" if admissible != true && admissibility_reason.to_s.empty?
        reasons << "below_min_confidence" if confidence_below?(min_confidence)
        if reasons.empty?
          reasons << "reviewer_requested_discussion" if route.to_s == "discuss"
          reasons << "reviewer_dismissed" if route.to_s == "dismiss"
        end
        reasons.uniq
      end

      private

      def confidence_below?(minimum)
        !Hive::Patrol::Fingerprint.fixable_confidence?(self, minimum)
      end
    end
  end
end
