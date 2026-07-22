require "time"
require "hive/patrol/fingerprint"

module Hive
  module Patrol
    # Owns the persistence boundary for reviewer output. A review finding is
    # only durable after it has an exact scan SHA and has been compared with
    # every prior finding, including records that never reached a PR ledger.
    class FindingRegistry
      Result = Struct.new(:findings, :persistable_findings, :skipped, keyword_init: true)
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

      def admit(findings, persist: true, retry_active: false)
        admitted = []
        persistable = []
        skipped = []
        returned_ids = {}

        Array(findings).each do |finding|
          finding.target_sha = @target_sha
          matches = semantic_matches(finding)
          same_target = matches.select { |candidate| candidate.target_sha.to_s.downcase == @target_sha }
          canonical = same_target.find { |candidate| lifecycle(candidate) != "active" } || same_target.first

          if canonical
            if retry_active && lifecycle(canonical) == "active" && !returned_ids[canonical.id.to_s]
              admitted << canonical
              returned_ids[canonical.id.to_s] = true
            else
              skipped << skip_entry(finding, canonical)
            end
            next
          end

          terminal_recurrence = matches.any? do |candidate|
            %w[resolved rejected].include?(lifecycle(candidate))
          end
          supersede_active_matches(matches, finding, persist: persist)
          activate(finding, reason: terminal_recurrence ? "recurrence_after_terminal" : "admitted")
          unless returned_ids[finding.id.to_s]
            admitted << finding
            returned_ids[finding.id.to_s] = true
          end
          persistable << finding
          index(finding)
        end

        Result.new(findings: admitted, persistable_findings: persistable, skipped: skipped)
      end

      # PR/dismissal ledgers are authoritative terminal evidence. Reconcile
      # lifecycle state before selecting new work so merged and explicitly
      # dismissed findings do not continue to appear active indefinitely.
      def reconcile!(fingerprints:, dismissed:, persist: true)
        @existing.each do |finding|
          next if lifecycle(finding) == "superseded"

          fingerprint = finding.fingerprint.to_s
          ledger = fingerprints[fingerprint]
          ledger_state = ledger.is_a?(Hash) ? ledger["state"].to_s : ""
          dismissal = dismissed[fingerprint]
          if %w[merged resolved].include?(ledger_state) && ledger_applies?(ledger, finding)
            transition(finding, "resolved", "patrol_pr_#{ledger_state}", persist: persist)
          elsif dismissal.is_a?(Hash) && ledger_applies?(dismissal, finding)
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

      def activate(finding, reason:)
        finding.lifecycle_state = "active"
        finding.lifecycle_reason = reason
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

      def ledger_applies?(entry, finding)
        ledger_target = entry["target_sha"].to_s.downcase
        if ledger_target.empty?
          return finding.lifecycle_reason.to_s != "recurrence_after_terminal"
        end

        ledger_target == finding.target_sha.to_s.downcase
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
