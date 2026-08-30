require "digest"
require "hive/lock"
require "hive/proposals/authority"
require "hive/proposals/ingestor"
require "hive/proposals/store"

module Hive
  module Proposals
    LifecycleResult = Data.define(:applied, :event, :projection) do
      def noop? = !applied
    end

    class DecisionService
      def initialize(store:, authority:, git_ops: nil, policy: DEFAULT_POLICY,
                     clock: -> { Time.now.utc })
        @store = store
        @authority = authority
        @git_ops = git_ops
        @policy = Proposals.policy!(policy)
        @clock = clock
      end

      def decide(proposal_id:, outcome:, considered_evaluation_ids:, rationale_category:,
                 rationale:, links:, expected_head:, authority_identity:,
                 expected_policy_fingerprint:, idempotency_key:, provenance:,
                 policy_receipt: nil)
        proposal_id = Proposals.proposal_id!(proposal_id)
        source_event_id = source_id("decision", idempotency_key)
        with_lifecycle_commit(proposal_id, "decision") do
          @store.transaction do |transaction|
            snapshot = transaction.snapshot
            projection = projection!(snapshot, proposal_id)
            evaluations = considered_evaluations!(projection, considered_evaluation_ids)
            authority = authorize!(
              identity: authority_identity, capability: "decide",
              expected_policy_fingerprint:, receipt: policy_receipt
            )
            data = {
              "outcome" => outcome, "considered_evaluation_ids" => evaluations.map(&:first),
              "considered_evaluations" => evaluations.map(&:last),
              "rationale_category" => rationale_category, "rationale" => rationale,
              "authority" => authority, "links" => links, "observed_head" => expected_head
            }
            normalized = Event.normalize_data("decision", data)
            if (existing = exact_retry(snapshot, source_event_id, proposal_id, "decision", normalized))
              next LifecycleResult.new(applied: false, event: existing, projection: projection)
            end
            raise Conflict, "proposal already has a terminal decision" if projection.decision
            validate_head!(projection, normalized.fetch("observed_head"))

            event = transaction.append_event!(
              proposal_id:, type: "decision", data: normalized, source_event_id:,
              provenance: lifecycle_provenance(provenance, authority, "decide"),
              occurred_at: @clock.call, event_id: nil, policy: @policy
            )
            LifecycleResult.new(
              applied: true, event:,
              projection: Projection.new(record: projection.record, events: projection.events + [ event ])
            )
          end
        end
      end

      def supersede(proposal_id:, successor_id:, expected_head:, authority_identity:,
                    expected_policy_fingerprint:, idempotency_key:, provenance:,
                    policy_receipt: nil)
        proposal_id = Proposals.proposal_id!(proposal_id)
        successor_id = Proposals.proposal_id!(successor_id)
        raise Conflict, "proposal cannot supersede itself" if successor_id == proposal_id
        source_event_id = source_id("supersession", idempotency_key)
        with_lifecycle_commit(proposal_id, "supersession") do
          @store.transaction do |transaction|
            snapshot = transaction.snapshot
            projection = projection!(snapshot, proposal_id)
            successor = projection!(snapshot, successor_id)
            authority = authorize!(
              identity: authority_identity, capability: "supersede",
              expected_policy_fingerprint:, receipt: policy_receipt
            )
            data = {
              "successor_id" => successor_id, "authority" => authority,
              "observed_head" => expected_head
            }
            normalized = Event.normalize_data("supersession", data)
            if (existing = exact_retry(snapshot, source_event_id, proposal_id, "supersession", normalized))
              next LifecycleResult.new(applied: false, event: existing, projection: projection)
            end
            validate_head!(projection, normalized.fetch("observed_head"))
            validate_supersession!(snapshot, projection, successor)

            event = transaction.append_event!(
              proposal_id:, type: "supersession", data: normalized, source_event_id:,
              provenance: lifecycle_provenance(provenance, authority, "supersede"),
              occurred_at: @clock.call, event_id: nil, policy: @policy
            )
            updated = transaction.snapshot
            LifecycleResult.new(
              applied: true, event:, projection: projection!(updated, proposal_id)
            )
          end
        end
      end

      def rollback(proposal_id:, reverted_revision:, reason:, external_revert:,
                   expected_head:, authority_identity:, expected_policy_fingerprint:,
                   idempotency_key:, provenance:, policy_receipt: nil)
        proposal_id = Proposals.proposal_id!(proposal_id)
        source_event_id = source_id("rollback", idempotency_key)
        with_lifecycle_commit(proposal_id, "rollback") do
          @store.transaction do |transaction|
            snapshot = transaction.snapshot
            projection = projection!(snapshot, proposal_id)
            authority = authorize!(
              identity: authority_identity, capability: "rollback",
              expected_policy_fingerprint:, receipt: policy_receipt
            )
            data = {
              "reverted_revision" => reverted_revision, "reason" => reason,
              "external_revert" => external_revert, "authority" => authority,
              "observed_head" => expected_head
            }
            normalized = Event.normalize_data("rollback", data)
            if (existing = exact_retry(snapshot, source_event_id, proposal_id, "rollback", normalized))
              next LifecycleResult.new(applied: false, event: existing, projection: projection)
            end
            validate_head!(projection, normalized.fetch("observed_head"))
            unless projection.decision&.fetch("outcome", nil) == "accepted"
              raise Conflict, "proposal rollback requires historical acceptance"
            end
            raise Conflict, "proposal already has a rollback" if projection.rollback
            unless normalized.fetch("reverted_revision") == projection.revision
              raise Conflict, "proposal rollback revision does not match accepted candidate"
            end

            event = transaction.append_event!(
              proposal_id:, type: "rollback", data: normalized, source_event_id:,
              provenance: lifecycle_provenance(provenance, authority, "rollback"),
              occurred_at: @clock.call, event_id: nil, policy: @policy
            )
            LifecycleResult.new(
              applied: true, event:,
              projection: Projection.new(record: projection.record, events: projection.events + [ event ])
            )
          end
        end
      end

      private

      def authorize!(identity:, capability:, expected_policy_fingerprint:, receipt:)
        @authority.authorize!(
          identity:, capability:, expected_policy_fingerprint:, receipt:
        )
      end

      def considered_evaluations!(projection, ids)
        normalized = Array(ids).map { |id| Proposals.event_id!(id) }.uniq.sort
        unless normalized.length == Array(ids).length
          raise StaleObservation, "considered proposal evaluations must be unique"
        end
        by_id = projection.evaluations.to_h { |evaluation| [ evaluation.fetch("event_id"), evaluation ] }
        normalized.map do |event_id|
          evaluation = by_id[event_id]
          raise StaleObservation, "considered proposal evaluation is missing" unless evaluation
          [
            event_id,
            {
              "evaluation_id" => event_id,
              "evaluator_id" => evaluation.dig("evaluator", "id"),
              "method" => evaluation.dig("method", "label"),
              "outcome" => evaluation.dig("result", "outcome"),
              "result_digest" => Proposals.digest(evaluation.fetch("result"))
            }
          ]
        end
      end

      def exact_retry(snapshot, source_event_id, proposal_id, type, normalized_data)
        record = snapshot.records.find { |candidate| candidate.source_event_id == source_event_id }
        raise Conflict, "lifecycle source event collides with a candidate" if record
        event = snapshot.events.values.flatten.find { |candidate| candidate.source_event_id == source_event_id }
        return nil unless event
        unless event.proposal_id == proposal_id && event.type == type && event.data == normalized_data
          raise Conflict, "lifecycle source event conflicts with its immutable event"
        end
        event
      end

      def validate_head!(projection, expected)
        observed = Event.observed_head!(expected)
        return if observed == projection.lifecycle_head

        raise StaleObservation, "proposal lifecycle head changed; refresh the observation"
      end

      def validate_supersession!(snapshot, predecessor, successor)
        raise Conflict, "proposal is already superseded" if predecessor.superseded_by
        unless predecessor.subject == successor.subject
          raise Conflict, "proposal supersession requires a matching subject"
        end
        requested = successor.record["lineage"]["requested_supersedes"]
        unless requested == predecessor.proposal_id
          raise Conflict, "proposal successor did not request this predecessor"
        end
        duplicate = snapshot.projections.find do |projection|
          projection.proposal_id != predecessor.proposal_id &&
            projection.superseded_by == successor.proposal_id
        end
        raise Conflict, "proposal successor already supersedes another candidate" if duplicate
        current = successor
        seen = []
        while current
          raise Conflict, "proposal supersession would create a lineage cycle" if
            current.proposal_id == predecessor.proposal_id
          break if seen.include?(current.proposal_id)
          seen << current.proposal_id
          next_id = current.superseded_by || current.record["lineage"]["retries"]
          current = next_id && snapshot.projections.find { |item| item.proposal_id == next_id }
        end
      end

      def projection!(snapshot, proposal_id)
        projection = snapshot.projections.find { |candidate| candidate.proposal_id == proposal_id }
        return projection if projection
        raise InvalidRecord, "proposal is missing or quarantined"
      end

      def lifecycle_provenance(value, authority, capability)
        provenance = Proposals.stringify(value)
        provenance["actor"] = {
          "id" => authority.fetch("id"), "kind" => "lifecycle_authority",
          "capability" => capability
        }
        Proposals.provenance!(provenance, error: InvalidEvent)
      end

      def source_id(kind, idempotency_key)
        key = idempotency_key.to_s
        raise InvalidEvent, "lifecycle idempotency key is required" if key.empty?
        "pse-#{Digest::SHA256.hexdigest("hive-proposal-#{kind}-v1\0#{key}")}"
      end

      def with_lifecycle_commit(proposal_id, action)
        runner = lambda do
          snapshot = Ingestor::PathSnapshot.capture(
            [ File.join(@store.events_root, proposal_id) ]
          )
          result = yield
          if result.applied && @git_ops
            path = relative_state_path(@store.path_for_event(result.event))
            begin
              @git_ops.hive_commit(
                stage_name: "proposals", slug: proposal_id,
                action: "recorded #{action}", pathspecs: [ path ]
              )
            rescue StandardError
              snapshot.restore!
              unstage!([ path ])
              raise
            end
          end
          result
        end
        return runner.call unless @git_ops

        Hive::Lock.with_commit_lock(@git_ops.hive_state_path) { runner.call }
      end

      def relative_state_path(path)
        prefix = "#{File.expand_path(@git_ops.hive_state_path)}/"
        absolute = File.expand_path(path)
        raise Error, "proposal lifecycle path is outside hive state" unless absolute.start_with?(prefix)
        absolute.delete_prefix(prefix)
      end

      def unstage!(paths)
        @git_ops.run_git!("-C", @git_ops.hive_state_path, "reset", "-q", "HEAD", "--", *paths)
      rescue Hive::GitError
        nil
      end
    end
  end
end
