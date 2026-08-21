require "hive/patrol_fix/admission_store"
require "securerandom"

module Hive
  module PatrolFix
    class SemanticAdmission
      class InvalidDecision < Hive::Error; end

      attr_reader :store

      def initialize(store:, candidate_provider:, decision_provider:,
                     current_head:, exact_provider: nil, clock: -> { Time.now.utc })
        @store = store
        @candidate_provider = candidate_provider
        @decision_provider = decision_provider
        @current_head = current_head
        @exact_provider = exact_provider
        @clock = clock
      end

      def call(occurrence_id:, snapshot:)
        now = @clock.call
        prepared = prepare(
          occurrence_id: occurrence_id, snapshot: snapshot,
          reservation_id: SecureRandom.hex(32), lease_expires_at: now + 7_200,
          now: now
        )
        return prepared unless prepared.fetch("status") == "deciding"

        run_reserved(
          occurrence_id: occurrence_id,
          reservation_id: prepared.dig("decision_reservation", "reservation_id")
        )
      end

      # Parent-daemon phase: freeze one full inventory digest and one bounded
      # relevance context, then persist the exact child reservation. No model
      # work is performed here.
      def prepare(occurrence_id:, snapshot:, reservation_id:, lease_expires_at:,
                  now: @clock.call)
        source = snapshot.is_a?(SourceSnapshot) ? snapshot : SourceSnapshot.new(snapshot)
        @store.reserve!(occurrence_id: occurrence_id, snapshot: source, now: now)
        if @exact_provider && (exact = @exact_provider.call(snapshot))
          prepared = @store.prepare_decision!(
            occurrence_id, candidates: [ exact ], current_head: @current_head.call,
            reservation_id: reservation_id, lease_expires_at: lease_expires_at,
            now: now
          )
          return @store.record_decision!(
            occurrence_id,
            candidate_digest: prepared.fetch("candidate_digest"),
            reservation_id: reservation_id,
            decision: "same_root",
            candidate_identity: exact.fetch("identity"),
            rationale: "exact identity match",
            evidence: [ "Controller-owned exact identity matched before semantic admission." ],
            model_receipt: "deterministic:exact-identity",
            now: now
          )
        end

        before = candidate_set(@candidate_provider.call(source))
        head = @current_head.call
        @store.prepare_decision!(
          occurrence_id, candidates: before.fetch("candidates"),
          inventory: inventory_descriptor(before), current_head: head,
          reservation_id: reservation_id, lease_expires_at: lease_expires_at,
          now: now
        )
      end

      # Supervised-child phase: the provider runs once over the frozen top-64
      # context. Full owned inventory and head are checked before launch and
      # again before the exact reservation may settle.
      def run_reserved(occurrence_id:, reservation_id:, now: @clock.call)
        prepared = @store.fetch(occurrence_id)
        unless prepared && prepared.fetch("status") == "deciding" &&
               prepared.dig("decision_reservation", "reservation_id") == reservation_id.to_s
          raise AdmissionStore::StaleDecision, "semantic admission reservation changed"
        end
        snapshot = SourceSnapshot.new(prepared.fetch("source"))
        revalidate!(occurrence_id, reservation_id, snapshot, prepared, now: now)
        decision = @decision_provider.call(decision_input(snapshot, prepared))
        revalidate!(occurrence_id, reservation_id, snapshot, prepared, now: now)
        record_decision(occurrence_id, reservation_id, prepared, decision, now: now)
      end

      private

      def decision_input(snapshot, prepared)
        {
          "schema" => "hive-patrol-fix-semantic-input",
          "schema_version" => 2,
          "source" => snapshot.to_h,
          "candidate_digest" => prepared.fetch("candidate_digest"),
          "current_head" => prepared.fetch("current_head"),
          "inventory_count" => prepared.dig("candidate_inventory", "count"),
          "inventory_digest" => prepared.dig("candidate_inventory", "digest"),
          "candidate_context_digest" => prepared.dig("candidate_inventory", "context_digest"),
          "candidate_context_truncated" => prepared.dig("candidate_inventory", "truncated"),
          "candidates" => prepared.fetch("candidates")
        }.freeze
      end

      def record_decision(occurrence_id, reservation_id, prepared, decision, now:)
        unless decision.is_a?(Hash) &&
               decision.keys.sort == %w[
                 candidate_identity decision evidence model_receipt rationale
               ].sort
          raise InvalidDecision, "semantic admission provider returned invalid fields"
        end
        @store.record_decision!(
          occurrence_id,
          candidate_digest: prepared.fetch("candidate_digest"),
          reservation_id: reservation_id,
          decision: decision.fetch("decision"),
          candidate_identity: decision["candidate_identity"],
          rationale: decision.fetch("rationale"),
          evidence: decision.fetch("evidence"),
          model_receipt: decision.fetch("model_receipt"),
          now: now
        )
      end

      def revalidate!(occurrence_id, reservation_id, snapshot, prepared, now:)
        current = candidate_set(@candidate_provider.call(snapshot))
        current_digest = @store.candidate_digest(
          current.fetch("candidates"), current_head: @current_head.call,
          inventory: inventory_descriptor(current)
        )
        return if current_digest == prepared.fetch("candidate_digest")

        @store.reset_stale!(
          occurrence_id, reservation_id: reservation_id, now: now
        )
        raise AdmissionStore::StaleDecision,
              "admission candidate set changed (inventory or head) while deciding"
      end

      def candidate_set(value)
        if value.is_a?(Array)
          digest = Digest::SHA256.hexdigest(PatrolFix.canonical_json(value))
          return {
            "inventory_count" => value.length,
            "inventory_digest" => digest, "context_digest" => digest,
            "truncated" => false, "candidates" => value
          }
        end
        required = %w[
          candidates context_digest inventory_count inventory_digest truncated
        ]
        unless value.is_a?(Hash) && value.keys.sort == required.sort
          raise InvalidDecision, "candidate inventory returned invalid fields"
        end
        value
      end

      def inventory_descriptor(value)
        {
          "count" => value.fetch("inventory_count"),
          "digest" => value.fetch("inventory_digest"),
          "context_digest" => value.fetch("context_digest"),
          "truncated" => value.fetch("truncated")
        }
      end
    end
  end
end
