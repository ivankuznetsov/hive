module Hive
  module RefactorPatrol
    Thesis = Struct.new(
      :id, :feature_id, :feature, :problem, :cost, :evidence,
      :proposed_refactor, :feature_boundary, :feature_hotspot, :expected_leverage,
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
          "feature_hotspot" => feature_hotspot || {},
          "expected_leverage" => expected_leverage || {},
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
          feature_hotspot: hash.fetch("feature_hotspot", {}),
          expected_leverage: hash.fetch("expected_leverage"),
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
    end
  end
end
