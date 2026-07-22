module Hive
  module Patrol
    Finding = Struct.new(
      :id, :feature_id, :category, :severity, :confidence, :title,
      :description, :recommendation, :scope, :contract, :impact,
      :root_cause, :reproduction, :validation, :evidence, :alpha_score,
      :fingerprint, :validation_key, :target_sha, :lifecycle_state,
      :lifecycle_reason, :lifecycle_updated_at, :superseded_by,
      keyword_init: true
    ) do
      def to_h
        {
          "id" => id,
          "feature_id" => feature_id,
          "category" => category,
          "severity" => severity,
          "confidence" => confidence,
          "title" => title,
          "description" => description,
          "recommendation" => recommendation,
          "scope" => scope,
          "contract" => contract,
          "impact" => impact,
          "root_cause" => root_cause,
          "reproduction" => reproduction,
          "validation" => validation,
          "evidence" => Array(evidence),
          "alpha_score" => alpha_score,
          "fingerprint" => fingerprint,
          "validation_key" => validation_key,
          "target_sha" => target_sha,
          "lifecycle_state" => lifecycle_state,
          "lifecycle_reason" => lifecycle_reason,
          "lifecycle_updated_at" => lifecycle_updated_at,
          "superseded_by" => superseded_by
        }.compact
      end

      def self.from_h(hash)
        new(
          id: hash.fetch("id"),
          feature_id: hash.fetch("feature_id"),
          category: hash.fetch("category"),
          severity: hash.fetch("severity"),
          confidence: hash.fetch("confidence"),
          title: hash["title"],
          description: hash["description"],
          recommendation: hash["recommendation"],
          scope: hash["scope"],
          contract: hash["contract"],
          impact: hash["impact"],
          root_cause: hash["root_cause"],
          reproduction: hash["reproduction"],
          validation: hash["validation"],
          evidence: Array(hash["evidence"]),
          alpha_score: hash["alpha_score"],
          fingerprint: hash["fingerprint"],
          validation_key: hash["validation_key"],
          target_sha: hash["target_sha"],
          lifecycle_state: hash["lifecycle_state"] || "active",
          lifecycle_reason: hash["lifecycle_reason"],
          lifecycle_updated_at: hash["lifecycle_updated_at"],
          superseded_by: hash["superseded_by"]
        )
      end
    end
    Finding.const_set(:LIFECYCLE_STATES, %w[active resolved rejected superseded].freeze)
  end
end
