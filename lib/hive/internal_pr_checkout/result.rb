require "hive/secret_patterns"

module Hive
  module InternalPrCheckout
    MAX_GUIDANCE_BYTES = 512

    class Error < Hive::Error
      attr_reader :reason, :retryable, :guidance

      def initialize(reason, guidance = nil, retryable: false)
        @reason = reason.to_s.freeze
        @retryable = retryable == true
        @guidance = Result.sanitize_guidance(guidance || reason.to_s)
        super(@guidance)
      end
    end

    class PendingInvalid < Error
      def initialize(guidance = "pending internal PR checkout transaction is invalid")
        super("pending_invalid", guidance, retryable: false)
      end
    end

    class CustodyError < Error; end

    Result = Data.define(
      :status,
      :reason,
      :retryable,
      :task_slug,
      :task_id,
      :pr_number,
      :pr_url,
      :generation,
      :head_oid,
      :previous_head_oid,
      :candidate_oid,
      :checkout_digest,
      :transaction_id,
      :pr_observation,
      :guidance
    ) do
      STATUSES = %w[not_applicable current reopened busy blocked].freeze
      REASONS_BY_STATUS = {
        "not_applicable" => %w[not_internal_pr_review].freeze,
        "current" => %w[head_unchanged pending_recovered_current].freeze,
        "reopened" => %w[head_changed pending_recovered_reopened].freeze,
        "busy" => %w[task_locked manual_steering].freeze,
        "blocked" => %w[
          pointer_missing
          pointer_malformed
          pointer_unowned
          pr_metadata_invalid
          sidecar_inconsistent
          checkout_dirty
          checkout_detached
          checkout_diverged
          candidate_unproven
          pending_invalid
          git_residue_unverifiable
          custody_limit_exceeded
          custody_mismatch
          git_config_unsafe
          remote_identity_invalid
          remote_changed_before_linearization
          provider_unavailable
          remote_observation_required
          transition_interrupted
        ].freeze
      }.freeze

      RETRYABLE_REASONS = %w[
        task_locked
        remote_changed_before_linearization
        provider_unavailable
        remote_observation_required
        transition_interrupted
      ].freeze

      def initialize(status:, reason:, retryable: nil, task_slug: nil, task_id: nil,
                     pr_number: nil, pr_url: nil, generation: nil, head_oid: nil,
                     previous_head_oid: nil, candidate_oid: nil, checkout_digest: nil,
                     transaction_id: nil, pr_observation: nil, guidance: "")
        normalized_status = status.to_s
        unless STATUSES.include?(normalized_status)
          raise ArgumentError, "unknown internal PR checkout status: #{status.inspect}"
        end

        normalized_reason = reason.to_s
        allowed = REASONS_BY_STATUS.fetch(normalized_status)
        unless allowed.include?(normalized_reason)
          raise ArgumentError,
                "invalid reason #{normalized_reason.inspect} for status #{normalized_status.inspect}"
        end

        is_retryable = retryable.nil? ? RETRYABLE_REASONS.include?(normalized_reason) : (retryable == true)
        super(
          status: normalized_status.freeze,
          reason: normalized_reason.freeze,
          retryable: is_retryable,
          task_slug: task_slug&.to_s&.dup&.freeze,
          task_id: task_id&.to_s&.dup&.freeze,
          pr_number: pr_number ? Integer(pr_number) : nil,
          pr_url: pr_url&.to_s&.dup&.freeze,
          generation: generation ? Integer(generation) : nil,
          head_oid: head_oid&.to_s&.downcase&.freeze,
          previous_head_oid: previous_head_oid&.to_s&.downcase&.freeze,
          candidate_oid: candidate_oid&.to_s&.downcase&.freeze,
          checkout_digest: checkout_digest&.to_s&.downcase&.freeze,
          transaction_id: transaction_id&.to_s&.dup&.freeze,
          pr_observation: pr_observation ? deep_freeze_hash(pr_observation) : nil,
          guidance: self.class.sanitize_guidance(guidance)
        )
      end

      def self.not_applicable(task: nil, guidance: "task is not an internal PR review")
        new(
          status: "not_applicable",
          reason: "not_internal_pr_review",
          retryable: false,
          task_slug: task&.respond_to?(:slug) ? task.slug : nil,
          task_id: task&.respond_to?(:id) ? task.id : nil,
          guidance: guidance
        )
      end

      def self.sanitize_guidance(value)
        redacted = Hive::SecretPatterns.redact(value.to_s).to_s
        text = redacted.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/[\r\n\t]+/, " ").strip
        return text.freeze if text.bytesize <= MAX_GUIDANCE_BYTES

        suffix = "..."
        slice = text.byteslice(0, MAX_GUIDANCE_BYTES - suffix.bytesize)
        slice = slice.dup.force_encoding(Encoding::UTF_8).scrub("")
        "#{slice}#{suffix}".freeze
      rescue StandardError
        "[redacted guidance]".freeze
      end

      def not_applicable? = status == "not_applicable"
      def current? = status == "current"
      def reopened? = status == "reopened"
      def busy? = status == "busy"
      def blocked? = status == "blocked"
      def proceed? = current? || reopened?

      def to_h
        data = {
          "status" => status,
          "reason" => reason,
          "retryable" => retryable,
          "guidance" => guidance
        }
        data["task_slug"] = task_slug if task_slug
        data["task_id"] = task_id if task_id
        data["pr_number"] = pr_number if pr_number
        data["pr_url"] = pr_url if pr_url
        data["generation"] = generation if generation
        data["head_oid"] = head_oid if head_oid
        data["previous_head_oid"] = previous_head_oid if previous_head_oid
        data["candidate_oid"] = candidate_oid if candidate_oid
        data["transaction_id"] = transaction_id if transaction_id
        data
      end

      def to_text
        parts = [ "hive: internal-pr reconciliation status=#{status} reason=#{reason}" ]
        parts << "pr=##{pr_number}" if pr_number
        parts << "gen=#{generation}" if generation
        parts << "head=#{head_oid[0, 12]}" if head_oid
        parts << "prev=#{previous_head_oid[0, 12]}" if previous_head_oid
        line = parts.join(" ")
        guidance.to_s.empty? ? line : "#{line} — #{guidance}"
      end

      private

      def deep_freeze_hash(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_s.dup.freeze] = deep_freeze_hash(v) }.freeze
        when Array
          value.map { |item| deep_freeze_hash(item) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end
    end
  end
end
