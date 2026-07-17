require "digest"
require "json"

module Hive
  module RefactorPatrol
    # Pure helpers for the append-only publication namespace owned by one
    # validated patch. Identity follows patch/base content rather than an
    # ephemeral action-claim generation so crash recovery can resume it.
    module PublicationAttempt
      class Error < StandardError; end

      ATTEMPTS_KEY = "publication_attempts".freeze
      PHASES = %w[push_intent push_complete pr_create_intent].freeze
      DESCRIPTOR_KEYS = %w[
        attempt_id patch_receipt_key publication_base_sha commit_sha recorded_at
      ].freeze
      SUPERSEDED_KEYS = %w[reason observed_head_sha recorded_at].freeze

      module_function

      def id_for(publication_base_sha:, commit_sha:)
        ::Digest::SHA256.hexdigest("#{publication_base_sha}\0#{commit_sha}")
      end

      def descriptor(patch_receipt_key:, publication_base_sha:, commit_sha:, recorded_at:)
        {
          "attempt_id" => id_for(
            publication_base_sha: publication_base_sha,
            commit_sha: commit_sha
          ),
          "patch_receipt_key" => patch_receipt_key,
          "publication_base_sha" => publication_base_sha,
          "commit_sha" => commit_sha,
          "recorded_at" => recorded_at
        }
      end

      def build(descriptor:, legacy_receipts: {})
        { "descriptor" => descriptor }.merge(legacy_phases(legacy_receipts, descriptor))
      end

      def ensure_for_patch(receipts:, patch_receipt:, recorded_at:, continuation_only: false)
        state = deep_copy(receipts)
        payload = deep_copy(patch_receipt)
        unless state.is_a?(Hash) && payload.is_a?(Hash) &&
               payload["publication_base_sha"].is_a?(String) && payload["commit_sha"].is_a?(String)
          raise Error, "publication patch receipt has invalid identity"
        end

        attempt_id = id_for(
          publication_base_sha: payload.fetch("publication_base_sha"),
          commit_sha: payload.fetch("commit_sha")
        )
        patch_keys = ordered_patch_keys(state)
        patch_key = patch_keys.find { |key| state.fetch(key) == payload }
        attempts = state[ATTEMPTS_KEY]
        raise Error, "publication attempts receipt is invalid" unless attempts.nil? || attempts.is_a?(Hash)

        attempts ||= {}
        if (existing = attempts[attempt_id])
          stored = existing.is_a?(Hash) ? existing["descriptor"] : nil
          unless stored.is_a?(Hash) && patch_key && stored["patch_receipt_key"] == patch_key &&
                 stored["publication_base_sha"] == payload["publication_base_sha"] &&
                 stored["commit_sha"] == payload["commit_sha"]
            raise Error, "publication attempt identity is immutable"
          end
          return state
        end

        if attempts.values.any? { |attempt| active?(attempt) }
          raise Error, "another publication attempt is still active"
        end
        if patch_key.nil? && continuation_only
          raise Error, "revoked action claim cannot record a replacement patch"
        end

        unless patch_key
          patch_key = next_patch_key(patch_keys)
          state[patch_key] = payload
        end
        descriptor = descriptor(
          patch_receipt_key: patch_key,
          publication_base_sha: payload.fetch("publication_base_sha"),
          commit_sha: payload.fetch("commit_sha"),
          recorded_at: recorded_at
        )
        attempts[attempt_id] = build(descriptor: descriptor, legacy_receipts: state)
        state[ATTEMPTS_KEY] = attempts
        state
      end

      def append_phase(receipts:, attempt_id:, phase:, payload:, continuation_only: false)
        state = deep_copy(receipts)
        id = attempt_id.to_s
        phase_name = phase.to_s
        value = deep_copy(payload)
        unless id.match?(/\A[a-f0-9]{64}\z/) && PHASES.include?(phase_name) &&
               value.is_a?(Hash) && value.any?
          raise Error, "publication attempt phase is invalid"
        end

        attempt = state.dig(ATTEMPTS_KEY, id)
        raise Error, "publication attempt is missing" unless attempt.is_a?(Hash)
        raise Error, "superseded publication attempt cannot advance" if attempt.key?("superseded")
        if attempt.key?(phase_name)
          raise Error, "publication attempt phase is immutable" unless attempt.fetch(phase_name) == value

          return state
        end
        if continuation_only && !(phase_name == "push_complete" && attempt["push_intent"].is_a?(Hash))
          raise Error, "revoked action claim cannot begin a publication phase"
        end
        if phase_name == "push_intent" && (attempt.key?("push_complete") || attempt.key?("pr_create_intent"))
          raise Error, "publication push intent cannot be appended after completion"
        end
        if phase_name == "push_complete" && attempt.key?("pr_create_intent")
          raise Error, "publication push completion cannot follow PR-create intent"
        end
        if phase_name == "pr_create_intent" && !attempt["push_complete"].is_a?(Hash)
          raise Error, "publication PR-create intent requires durable push completion"
        end

        attempt[phase_name] = value
        state
      end

      def supersede(receipts:, attempt_id:, observed_head_sha:, recorded_at:)
        state = deep_copy(receipts)
        id = attempt_id.to_s
        observed = observed_head_sha.to_s
        unless id.match?(/\A[a-f0-9]{64}\z/) && observed.match?(/\A[a-f0-9]{40,64}\z/)
          raise Error, "publication supersession evidence is invalid"
        end

        attempt = state.dig(ATTEMPTS_KEY, id)
        raise Error, "publication attempt is missing" unless attempt.is_a?(Hash)
        stored = attempt["descriptor"]
        unless stored.is_a?(Hash) && stored["attempt_id"] == id
          raise Error, "publication attempt descriptor is invalid"
        end
        evidence = {
          "reason" => "trunk_drift_retry",
          "observed_head_sha" => observed,
          "recorded_at" => recorded_at
        }
        if (existing = attempt["superseded"])
          unless existing.is_a?(Hash) && existing.except("recorded_at") == evidence.except("recorded_at")
            raise Error, "publication supersession is immutable"
          end
          return state
        end
        raise Error, "post-create publication attempt cannot be superseded" if attempt.key?("pr_create_intent")
        if stored["publication_base_sha"] == observed
          raise Error, "publication supersession requires observed trunk drift"
        end

        attempt["superseded"] = evidence
        state
      end

      def active_patch_key(receipts)
        attempts = receipts[ATTEMPTS_KEY]
        raise Error, "publication attempts receipt is invalid" unless attempts.nil? || attempts.is_a?(Hash)

        if attempts&.any?
          active = attempts.values.select { |attempt| active?(attempt) }
          raise Error, "multiple publication attempts are active" if active.size > 1

          return active.first.dig("descriptor", "patch_receipt_key") if active.one?
        end

        referenced = attempts.to_h.values.filter_map do |attempt|
          attempt.dig("descriptor", "patch_receipt_key") if attempt.is_a?(Hash)
        end
        superseded = receipts.filter_map do |key, value|
          value["commit_sha"] if key.start_with?("patch_superseded_") && value.is_a?(Hash)
        end
        ordered_patch_keys(receipts).reverse.find do |key|
          next false if referenced.include?(key)

          receipt = receipts.fetch(key)
          receipt.is_a?(Hash) && !superseded.include?(receipt["commit_sha"])
        end
      end

      def state_for(receipts, attempt_id)
        attempt = receipts.dig(ATTEMPTS_KEY, attempt_id)
        return nil unless active?(attempt)

        PHASES.each_with_object({}) do |phase, state|
          state[phase] = attempt.fetch(phase) if attempt.key?(phase)
        end
      end

      def superseded_remote_commits(receipts)
        attempts = receipts[ATTEMPTS_KEY]
        namespaced = if attempts.is_a?(Hash)
          attempts.values.filter_map do |attempt|
            next unless attempt.is_a?(Hash) && attempt["superseded"].is_a?(Hash) &&
                        remote_push_evidence?(attempt)

            attempt.dig("descriptor", "commit_sha")
          end
        else
          []
        end

        patch_branches = ordered_patch_keys(receipts).each_with_object({}) do |key, index|
          patch = receipts[key]
          next unless patch.is_a?(Hash)

          commit = patch["commit_sha"].to_s
          branch = patch["branch"].to_s
          index[commit] = branch if commit.match?(/\A[a-f0-9]{40,64}\z/) && !branch.empty?
        end
        legacy = receipts.filter_map do |key, value|
          next unless key.start_with?("patch_superseded_") && value.is_a?(Hash)
          next unless value["reason"] == "trunk_drift_retry"

          commit = value["commit_sha"].to_s
          branch = patch_branches[commit]
          next unless branch
          next unless key == "patch_superseded_#{::Digest::SHA256.hexdigest(commit)}"
          next unless legacy_push_complete?(receipts["push_complete"], commit, branch)

          commit
        end
        (namespaced + legacy).compact.uniq.sort
      end

      def phase_evidence?(receipts)
        attempts = receipts[ATTEMPTS_KEY]
        attempts.is_a?(Hash) && attempts.values.any? do |attempt|
          attempt.is_a?(Hash) && PHASES.any? { |phase| attempt[phase].is_a?(Hash) }
        end
      end

      def legacy_phases(receipts, descriptor)
        return {} unless receipts.is_a?(Hash) && descriptor.is_a?(Hash)

        commit_sha = descriptor["commit_sha"]
        state = {}
        legacy_intent = receipts.dig("creation_intent", "payload")
        copy_legacy_phase!(state, legacy_intent, commit_sha)
        PHASES.drop(1).each do |phase|
          copy_legacy_phase!(state, receipts[phase], commit_sha, expected_phase: phase)
        end
        state
      end

      def active?(attempt)
        attempt.is_a?(Hash) && !attempt.key?("superseded")
      end

      def pre_create?(attempt)
        attempt.is_a?(Hash) && !attempt.key?("pr_create_intent")
      end

      def remote_push_evidence?(attempt)
        attempt.is_a?(Hash) && attempt["push_complete"].is_a?(Hash)
      end

      def legacy_push_complete?(payload, commit, branch)
        payload.is_a?(Hash) &&
          payload["operation"] == "push_branch_complete" &&
          payload["commit_sha"] == commit &&
          payload["remote_oid"] == commit &&
          payload["branch"] == branch
      end
      private_class_method :legacy_push_complete?

      def copy_legacy_phase!(state, payload, commit_sha, expected_phase: nil)
        return unless payload.is_a?(Hash) && payload["commit_sha"] == commit_sha

        phase = case payload["operation"]
        when "push_branch" then "push_intent"
        when "push_branch_complete" then "push_complete"
        when "create_pr" then "pr_create_intent"
        end
        return unless phase && (!expected_phase || phase == expected_phase)

        state[phase] = payload
      end
      private_class_method :copy_legacy_phase!

      def ordered_patch_keys(receipts)
        receipts.keys.grep(/\Apatch(?:_\d+)?\z/).sort_by do |key|
          key == "patch" ? 1 : key.delete_prefix("patch_").to_i
        end
      end
      private_class_method :ordered_patch_keys

      def next_patch_key(keys)
        sequence = keys.empty? ? 1 : keys.map do |key|
          key == "patch" ? 1 : key.delete_prefix("patch_").to_i
        end.max + 1
        sequence == 1 ? "patch" : "patch_#{sequence}"
      end
      private_class_method :next_patch_key

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
      private_class_method :deep_copy
    end
  end
end
