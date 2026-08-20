require "hive/patrol_fix/admission_store"

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
        @store.reserve!(occurrence_id: occurrence_id, snapshot: snapshot, now: @clock.call)
        if @exact_provider && (exact = @exact_provider.call(snapshot))
          prepared = @store.prepare_decision!(
            occurrence_id, candidates: [ exact ], current_head: @current_head.call,
            now: @clock.call
          )
          return @store.record_decision!(
            occurrence_id,
            candidate_digest: prepared.fetch("candidate_digest"),
            decision: "same_root",
            candidate_identity: exact.fetch("identity"),
            rationale: "exact identity match",
            evidence: [ "Controller-owned exact identity matched before semantic admission." ],
            model_receipt: "deterministic:exact-identity",
            now: @clock.call
          )
        end

        before = @candidate_provider.call(snapshot)
        head = @current_head.call
        prepared = @store.prepare_decision!(
          occurrence_id, candidates: before, current_head: head, now: @clock.call
        )

        # No AdmissionStore lock is held while the provider reasons.
        decision = @decision_provider.call(decision_input(snapshot, prepared))

        after = @candidate_provider.call(snapshot)
        after_head = @current_head.call
        current_digest = @store.candidate_digest(after, current_head: after_head)
        unless current_digest == prepared.fetch("candidate_digest")
          @store.reset_stale!(occurrence_id, now: @clock.call)
          raise AdmissionStore::StaleDecision,
                "admission candidate set changed while deciding"
        end
        record_decision(occurrence_id, prepared, decision)
      end

      private

      def decision_input(snapshot, prepared)
        {
          "schema" => "hive-patrol-fix-semantic-input",
          "schema_version" => 1,
          "source" => snapshot.to_h,
          "candidate_digest" => prepared.fetch("candidate_digest"),
          "current_head" => prepared.fetch("current_head"),
          "candidates" => prepared.fetch("candidates")
        }.freeze
      end

      def record_decision(occurrence_id, prepared, decision)
        unless decision.is_a?(Hash) &&
               decision.keys.sort == %w[
                 candidate_identity decision evidence model_receipt rationale
               ].sort
          raise InvalidDecision, "semantic admission provider returned invalid fields"
        end
        @store.record_decision!(
          occurrence_id,
          candidate_digest: prepared.fetch("candidate_digest"),
          decision: decision.fetch("decision"),
          candidate_identity: decision["candidate_identity"],
          rationale: decision.fetch("rationale"),
          evidence: decision.fetch("evidence"),
          model_receipt: decision.fetch("model_receipt"),
          now: @clock.call
        )
      rescue KeyError
        raise InvalidDecision, "semantic admission provider returned incomplete output"
      end
    end
  end
end
