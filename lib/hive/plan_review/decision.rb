require "json"
require "time"
require "hive/plan_review"
require "hive/plan_review/identity"

module Hive
  module PlanReview
    class Decision
      SCHEMA = "hive-plan-review-decision".freeze
      SCHEMA_VERSION = 1
      ACTIONS = %w[
        approve_finding answer_finding waive_coverage downgrade_level
        raise_level retry request_review
      ].freeze
      AUTHORITY_ACTIONS = %w[
        approve_finding answer_finding waive_coverage downgrade_level
      ].freeze
      ORIGINS = %w[cli web operator policy daemon].freeze
      POLICY_RECEIPT_KEYS = %w[
        policy_id policy_version policy_digest action risk path review_id
        policy_fingerprint matched_at
      ].freeze
      KEYS = %w[
        schema schema_version decision_id review_id task_generation policy_fingerprint
        expected_artifact_digest target_fingerprint action value reason origin operator
        policy_receipt decided_at
      ].freeze

      attr_reader :data

      def initialize(attributes)
        @data = Identity.normalize(attributes)
        validate!
        expected = Identity.decision(
          review_id: @data.fetch("review_id"),
          target_fingerprint: @data.fetch("target_fingerprint"),
          action: @data.fetch("action"),
          value: @data.fetch("value")
        )
        supplied = @data["decision_id"]
        if supplied && supplied != expected
          raise InvalidAction, "plan review decision id does not match its semantic action"
        end
        @data["decision_id"] = expected
        @data = JSON.parse(JSON.generate(@data)).freeze
        freeze
      rescue JSON::GeneratorError, TypeError => e
        raise InvalidAction, "plan review decision is not JSON-safe: #{e.message}"
      end

      def [](key) = data[key.to_s]
      def decision_id = self["decision_id"]
      def action = self["action"]
      def target_fingerprint = self["target_fingerprint"]
      def value = self["value"]
      def authority_action? = AUTHORITY_ACTIONS.include?(action)
      def to_h = JSON.parse(JSON.generate(data))

      private

      def validate!
        unknown = data.keys - KEYS
        missing = (KEYS - %w[decision_id policy_receipt]) - data.keys
        raise InvalidAction, "plan review decision has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
        raise InvalidAction, "plan review decision is missing fields: #{missing.join(', ')}" unless missing.empty?
        unless data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise InvalidAction, "invalid plan review decision envelope"
        end
        raise InvalidAction, "unknown plan review action" unless ACTIONS.include?(action)
        unless data["review_id"].to_s.match?(/\Apr-[0-9a-f]{64}\z/) &&
               data["policy_fingerprint"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               data["expected_artifact_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidAction, "plan review decision identity is malformed"
        end
        unless data["task_generation"].is_a?(String) && !data["task_generation"].empty? &&
               data["target_fingerprint"].is_a?(String) && !data["target_fingerprint"].empty?
          raise InvalidAction, "plan review decision target is malformed"
        end
        unless data["reason"].nil? || data["reason"].is_a?(String)
          raise InvalidAction, "plan review decision reason must be text"
        end
        unless ORIGINS.include?(data["origin"])
          raise InvalidAction, "plan review decision origin must be one of #{ORIGINS.inspect}"
        end
        unless data["operator"].is_a?(String) && !data["operator"].strip.empty?
          raise InvalidAction, "plan review decision operator must be non-empty"
        end
        raise InvalidAction, "plan review decision value must be a mapping" unless data["value"].is_a?(Hash)
        validate_policy_receipt!
        Time.iso8601(data.fetch("decided_at"))
      rescue ArgumentError, TypeError
        raise InvalidAction, "plan review decision decided_at must be ISO-8601"
      end

      def validate_policy_receipt!
        receipt = data["policy_receipt"]
        if data["origin"] == "policy" && !receipt.is_a?(Hash)
          raise InvalidAction, "policy-origin decision requires an approval policy receipt"
        end
        return if receipt.nil?
        unless data["origin"] == "policy" && receipt.keys.sort == POLICY_RECEIPT_KEYS.sort
          raise InvalidAction, "plan review approval policy receipt is malformed"
        end
        unless receipt["policy_id"].is_a?(String) && !receipt["policy_id"].empty? &&
               receipt["policy_version"].is_a?(Integer) && receipt["policy_version"].positive? &&
               receipt["policy_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               receipt["review_id"] == data["review_id"] &&
               receipt["policy_fingerprint"] == data["policy_fingerprint"]
          raise InvalidAction, "plan review approval policy receipt identity is malformed"
        end
        Time.iso8601(receipt.fetch("matched_at"))
      rescue ArgumentError, TypeError, KeyError
        raise InvalidAction, "plan review approval policy receipt is malformed"
      end
    end
  end
end
