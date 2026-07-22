require "time"
require "hive/patrol/fingerprint"

module Hive
  module Patrol
    # Owns the persistence boundary for reviewer output. A review finding is
    # only durable after it has an exact scan SHA and has been compared with
    # every prior finding, including records that never reached a PR ledger.
    class FindingRegistry
      Result = Struct.new(:findings, :skipped, keyword_init: true)

      def initialize(state:, target_sha:, clock: -> { Time.now })
        @state = state
        @target_sha = target_sha.to_s.downcase
        @clock = clock
        @existing = state.findings
      end

      def admit(findings, persist: true)
        admitted = []
        skipped = []

        Array(findings).each do |finding|
          finding.target_sha = @target_sha
          matches = (@existing + admitted).select do |candidate|
            Fingerprint.semantically_same?(candidate, finding)
          end
          terminal = matches.find { |candidate| %w[resolved rejected].include?(lifecycle(candidate)) }
          same_target = matches.find { |candidate| candidate.target_sha.to_s.downcase == @target_sha }

          if terminal || same_target
            canonical = terminal || same_target
            skipped << skip_entry(finding, canonical)
            next
          end

          supersede_active_matches(matches, finding, persist: persist)
          activate(finding)
          admitted << finding
        end

        Result.new(findings: admitted, skipped: skipped)
      end

      # PR/dismissal ledgers are authoritative terminal evidence. Reconcile
      # lifecycle state before selecting new work so merged and explicitly
      # dismissed findings do not continue to appear active indefinitely.
      def reconcile!(fingerprints:, dismissed:, persist: true)
        @existing.each do |finding|
          next if lifecycle(finding) == "superseded"

          fingerprint = finding.fingerprint.to_s
          ledger_state = fingerprints.dig(fingerprint, "state").to_s
          if %w[merged resolved].include?(ledger_state)
            transition(finding, "resolved", "patrol_pr_#{ledger_state}", persist: persist)
          elsif dismissed.key?(fingerprint)
            transition(finding, "rejected", "patrol_pr_dismissed", persist: persist)
          end
        end
      end

      def transition_current!(finding, state:, reason:, persist: true)
        transition(finding, state, reason, persist: persist)
      end

      private

      def supersede_active_matches(matches, replacement, persist:)
        matches.each do |candidate|
          next unless lifecycle(candidate) == "active"

          transition(
            candidate, "superseded", "newer_target_evidence",
            superseded_by: replacement.id, persist: persist
          )
        end
      end

      def activate(finding)
        finding.lifecycle_state = "active"
        finding.lifecycle_reason = "admitted"
        finding.lifecycle_updated_at = @clock.call.utc.iso8601
        finding.superseded_by = nil
      end

      def transition(finding, state, reason, superseded_by: nil, persist:)
        finding.lifecycle_state = state
        finding.lifecycle_reason = reason
        finding.lifecycle_updated_at = @clock.call.utc.iso8601
        finding.superseded_by = state == "superseded" ? superseded_by : nil
        return finding unless persist

        @state.transition_finding(
          finding.id, state: state, reason: reason,
          now: @clock.call, superseded_by: superseded_by
        )
      end

      def lifecycle(finding)
        finding.lifecycle_state.to_s.empty? ? "active" : finding.lifecycle_state.to_s
      end

      def skip_entry(finding, canonical)
        {
          "finding_id" => finding.id,
          "fingerprint" => finding.fingerprint,
          "reason" => "semantic_duplicate",
          "canonical_finding_id" => canonical.id
        }
      end
    end
  end
end
