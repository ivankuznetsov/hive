require "digest"
require "time"
require "hive/patrol_fix"
require "hive/patrol_fix/receipt_store"
require "hive/secret_patterns"

module Hive
  module PatrolFix
    module PublicationBlockReceipt
      CODE = "secret_detected".freeze
      OWNER = "operator".freeze
      SUMMARY = "Publication was blocked by the secret policy before any remote effect.".freeze
      BLOCKED_FIELDS = %w[title body diff].freeze
      REWORK_STAGES = %w[inbox fix review].freeze
      DIGEST = /\A[0-9a-f]{64}\z/
      REVISION = /\A[0-9a-f]{40}\z/

      class InvalidBlock < Hive::Error; end

      module_function

      def build(task:, evidence_revision:, blocked_fields:, rework_stage:,
                review_receipt_id:, fix_receipt_id:, validation_receipt_id:,
                head_revision:, diff_digest:, recorded_at: Time.now.utc)
        payload = {
          "code" => CODE,
          "owner" => OWNER,
          "summary" => SUMMARY,
          "blocked_fields" => BLOCKED_FIELDS.select { |field| blocked_fields.include?(field) },
          "rework_stage" => rework_stage,
          "review_receipt_id" => review_receipt_id,
          "fix_receipt_id" => fix_receipt_id,
          "validation_receipt_id" => validation_receipt_id,
          "head_revision" => head_revision,
          "diff_digest" => diff_digest,
          "secret_policy_version" => Hive::SecretPatterns::POLICY_VERSION
        }
        validate_payload!(payload)
        receipt_id = "publication-block-#{Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "task" => task, "stage" => "publish", "payload" => payload
        ))[0, 24]}"
        PatrolFix.deep_freeze(
          "schema" => ReceiptStore::SCHEMA,
          "schema_version" => ReceiptStore::SCHEMA_VERSION,
          "receipt_id" => receipt_id,
          "kind" => "publication_block",
          "stage" => "publish",
          "task" => task,
          "evidence_revision" => evidence_revision,
          "recorded_at" => recorded_at.utc.iso8601,
          "payload" => payload
        )
      end

      def validate_payload!(payload)
        fields = %w[
          code owner summary blocked_fields rework_stage review_receipt_id
          fix_receipt_id validation_receipt_id head_revision diff_digest
          secret_policy_version
        ]
        blocked_fields = payload["blocked_fields"] if payload.is_a?(Hash)
        ordered_fields = BLOCKED_FIELDS.select { |field| blocked_fields&.include?(field) }
        receipt_ids_valid = %w[review_receipt_id fix_receipt_id validation_receipt_id].all? do |key|
          bounded_id?(payload[key])
        end if payload.is_a?(Hash)
        unless payload.is_a?(Hash) && payload.keys.sort == fields.sort &&
               payload["code"] == CODE && payload["owner"] == OWNER &&
               payload["summary"] == SUMMARY &&
               blocked_fields.is_a?(Array) && !blocked_fields.empty? &&
               blocked_fields == ordered_fields &&
               REWORK_STAGES.include?(payload["rework_stage"]) &&
               receipt_ids_valid &&
               payload["head_revision"].to_s.match?(REVISION) &&
               payload["diff_digest"].to_s.match?(DIGEST) &&
               payload["secret_policy_version"] == Hive::SecretPatterns::POLICY_VERSION
          raise InvalidBlock, "publication block payload is invalid"
        end

        payload
      end

      def bounded_id?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= 128 &&
          !value.match?(/[\u0000-\u001f\u007f]/)
      end
      private_class_method :bounded_id?
    end
  end
end
