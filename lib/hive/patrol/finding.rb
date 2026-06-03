module Hive
  module Patrol
    Finding = Struct.new(
      :id, :feature_id, :category, :severity, :confidence, :title,
      :description, :recommendation, :evidence, :fingerprint,
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
          "evidence" => Array(evidence),
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
          evidence: Array(hash["evidence"]),
          fingerprint: hash["fingerprint"]
        )
      end
    end
  end
end
