require "time"
require "hive/patrol/fingerprint"

module Hive
  module Patrol
    # Owns the persistence boundary for reviewer output. A review finding is
    # only durable after it has an exact scan SHA and has been compared with
    # every prior finding, including records that never reached a PR ledger.
    class FindingRegistry
      Result = Struct.new(:findings, :skipped, keyword_init: true)
      IndexedFinding = Struct.new(:finding, :signature, keyword_init: true)

      def initialize(state:, target_sha:, clock: -> { Time.now })
        @state = state
        @target_sha = target_sha.to_s.downcase
        @clock = clock
        @existing = state.findings
        @exact_index = Hash.new { |hash, key| hash[key] = [] }
        @category_index = Hash.new { |hash, key| hash[key] = [] }
        @existing.each { |finding| index(finding) }
      end

      def admit(findings, persist: true)
        admitted = []
        skipped = []

        Array(findings).each do |finding|
          finding.target_sha = @target_sha
          matches = semantic_matches(finding)
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
          index(finding)
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
        target_superseded_by = state == "superseded" ? superseded_by : nil
        return finding if finding.lifecycle_state == state &&
                          finding.lifecycle_reason == reason &&
                          finding.superseded_by.to_s == target_superseded_by.to_s

        now = @clock.call
        unless persist
          finding.lifecycle_state = state
          finding.lifecycle_reason = reason
          finding.lifecycle_updated_at = now.utc.iso8601
          finding.superseded_by = target_superseded_by
          return finding
        end

        @state.transition_finding(
          finding, state: state, reason: reason,
          now: now, superseded_by: superseded_by
        )
      end

      def index(finding)
        signature = Fingerprint.semantic_signature(finding)
        indexed = IndexedFinding.new(finding: finding, signature: signature)
        @category_index[signature.fetch(:category)] << indexed
        fingerprint = signature.fetch(:fingerprint)
        @exact_index[fingerprint] << indexed unless fingerprint.empty?
      end

      def semantic_matches(finding)
        signature = Fingerprint.semantic_signature(finding)
        candidates = @category_index.fetch(signature.fetch(:category), []).dup
        fingerprint = signature.fetch(:fingerprint)
        candidates.concat(@exact_index.fetch(fingerprint, [])) unless fingerprint.empty?
        candidates.uniq! { |indexed| indexed.finding.object_id }
        candidates.filter_map do |indexed|
          indexed.finding if Fingerprint.semantically_same_signature?(indexed.signature, signature)
        end
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
