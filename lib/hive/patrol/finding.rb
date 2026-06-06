module Hive
  module Patrol
    Finding = Struct.new(
      :id, :feature_id, :category, :severity, :confidence, :title,
      :description, :recommendation, :evidence, :fingerprint,
      keyword_init: true
    ) do
      # Evidence arrives as unvalidated LLM JSON. The invariant is "an Array of
      # entry Hashes", but the model sometimes emits a single unwrapped object
      # (`"evidence": {…}`). Normalize once here, at the value-object boundary,
      # so every consumer can treat `evidence` as an Array without re-coercing:
      # a bare Hash becomes `[hash]` (one entry), not `Array(hash)`'s
      # `[[k, v], …]` decomposition that renders as mangled bullets downstream.
      def evidence
        raw = self[:evidence]
        return [ raw ] if raw.is_a?(Hash)

        Array(raw)
      end

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
          "evidence" => evidence,
          "fingerprint" => fingerprint
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
          evidence: hash["evidence"],
          fingerprint: hash["fingerprint"]
        )
      end
    end
  end
end
