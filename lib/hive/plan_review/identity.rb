require "digest"
require "json"
require "securerandom"
require "hive/plan_review"

module Hive
  module PlanReview
    module Identity
      module_function

      def logical(task_id:, plan_generation:, policy_fingerprint:)
        stable_id("pr", task_id:, plan_generation:, policy_fingerprint:)
      end

      def attempt(review_id)
        "pra-#{Digest::SHA256.hexdigest([ review_id, SecureRandom.uuid ].join("\0"))}"
      end

      def decision(review_id:, target_fingerprint:, action:, value:)
        stable_id(
          "prd",
          review_id:,
          target_fingerprint:,
          action: action.to_s,
          value: normalize(value)
        )
      end

      def coverage(review_id:, name:, policy_fingerprint:)
        stable_id("prc", review_id:, name: name.to_s, policy_fingerprint:)
      end

      def stable_id(prefix, attributes)
        "#{prefix}-#{Digest::SHA256.hexdigest(JSON.generate(normalize(attributes)))}"
      end

      def normalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            [ key, normalize(value.fetch(original)) ]
          end
        when Array then value.map { |entry| normalize(entry) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
