require "hive/modules/migration/patrol_evidence"

module Hive
  module RefactorPatrol
    # Owns architecture-patrol occurrence reservation, canonical finalization,
    # and projection recovery. Scheduler cadence and process dispatch remain
    # outside this persistence boundary.
    class ArchitectureOccurrenceLifecycle
      def initialize(migration_authority:, dry_run:, evidence_store_factory:,
                     event_publisher:, module_schedule:, reservation_error:)
        @migration_authority = migration_authority
        @dry_run = dry_run
        @evidence_store_factory = evidence_store_factory
        @event_publisher = event_publisher
        @module_schedule = module_schedule
        @reservation_error = reservation_error
      end

      def reserve(store:, entry:, aggregate:, migration:, now:)
        existing = store.occurrence_capture(aggregate.fetch("job_id"))
        if existing
          assert_same_owner!(existing, migration)
          return existing
        end

        source = aggregate.fetch("source")
        occurred_at = source["merged_at"] || aggregate.fetch("created_at")
        capture = Hive::Modules::Migration::PatrolCapture.build(
          module_name: "architecture-patrol",
          project: {
            "project_id" => entry.fetch("project_id"),
            "name" => entry.fetch("name"),
            "repository" => source.fetch("repository")
          },
          trigger: {
            "kind" => "pull_request.merged",
            "id" => [
              source.fetch("repository"),
              source.fetch("number"),
              source.fetch("merge_sha")
            ].join(":"),
            "manifest_digest" => source.fetch("manifest_checksum"),
            "merge_sha" => source.fetch("merge_sha")
          },
          reservation: {
            "kind" => "architecture",
            "id" => aggregate.fetch("job_id"),
            "job_id" => aggregate.fetch("job_id")
          },
          owner: migration.fetch("owner"),
          owner_epoch: migration.fetch("epoch"),
          decision_class: "provenance",
          decision: {
            "rationale" => "due",
            "job_id" => aggregate.fetch("job_id"),
            "phase" => "discovery"
          },
          occurred_at: occurred_at,
          recorded_at: occurred_at
        )
        unless @dry_run
          store.reserve_occurrence!(
            aggregate.fetch("job_id"), capture: capture, now: now
          )
        end
        capture
      end

      def publish_finalized(store:, entry:, token:, result:, aggregate:,
                            now:)
        return unless @migration_authority.to_sym == :legacy
        return unless token[:occurrence_id] && token[:migration_epoch]
        return unless aggregate && aggregate.fetch("complete") == true

        occurrence = store.occurrence_for_job(token.fetch(:job_id))
        return unless occurrence
        if occurrence.fetch("phase") == "finalized"
          drain(store, entry, occurrence.fetch("occurrence_id"))
          return
        end

        provisional = Hive::Modules::Migration::PatrolCapture.from_h(
          occurrence.fetch("provisional_capture")
        )
        capture = final_capture(
          store,
          provisional,
          token: token,
          result: result,
          aggregate: aggregate,
          now: now
        )
        event = @event_publisher.prepare_architecture_patrol_finalized(
          entry,
          capture,
          schedule: @module_schedule,
          target_hook:
            token.fetch(:phase).to_s == "action" ?
              "actions" : "scheduled-discovery"
        )
        store.finalize_occurrence!(
          capture: capture, event: event, now: now
        )
        drain(store, entry, capture.occurrence_id)
      end

      def recover(store:, entry:)
        return unless store.respond_to?(:projection_pending_occurrences)

        store.projection_pending_occurrences.each do |occurrence|
          drain(store, entry, occurrence.fetch("occurrence_id"))
        end
      end

      private

      def assert_same_owner!(capture, migration)
        return if capture.owner == migration.fetch("owner") &&
                  capture.owner_epoch == migration.fetch("epoch")

        raise @reservation_error.new(
          "architecture_patrol_occurrence_owner_changed"
        )
      end

      def final_capture(store, provisional, token:, result:, aggregate:, now:)
        actions = aggregate.fetch("actions")
        decision = {
          "rationale" => "complete",
          "job_id" => aggregate.fetch("job_id"),
          "state" => aggregate.fetch("state"),
          "zero_reason" => aggregate.fetch("zero_reason"),
          "action_count" => actions.size,
          "action_outcomes" => actions.to_h do |action|
            [
              action.fetch("canonical_action_id"),
              action.fetch("outcome")
            ]
          end,
          "completion_status" => result.fetch(:status).to_s
        }
        Hive::Modules::Migration::PatrolCapture.build(
          module_name: "architecture-patrol",
          project: provisional.project,
          trigger: provisional.trigger,
          reservation: provisional.reservation,
          owner: provisional.owner,
          owner_epoch: provisional.owner_epoch,
          decision_class: "complete",
          decision: decision,
          effect_ids: store.terminal_effect_receipt_ids(
            provisional.occurrence_id
          ),
          occurred_at: provisional.occurred_at,
          recorded_at: now
        )
      end

      def drain(store, entry, occurrence_id)
        store.drain_occurrence_outbox!(
          occurrence_id,
          evidence_store: @evidence_store_factory.call(entry),
          event_publisher: @event_publisher,
          project_entry: entry
        )
      end
    end
  end
end
