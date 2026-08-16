require "hive/config"
require "hive/modules/migration/patrol_evidence"
require "hive/refactor_patrol/decision_projection"

module Hive
  module RefactorPatrol
    # Owns architecture-patrol occurrence reservation, canonical finalization,
    # and projection recovery. Scheduler cadence and process dispatch remain
    # outside this persistence boundary.
    class ArchitectureOccurrenceLifecycle
      class RecoveryError < Hive::ConfigError
        attr_reader :occurrence_id, :job_id, :error_class

        def initialize(error:, occurrence_id:, job_id:)
          @occurrence_id = occurrence_id
          @job_id = job_id
          @error_class = error.class.name
          super(error.message)
        end
      end

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
        occurred_at = canonical_time(
          source["merged_at"] || aggregate.fetch("created_at")
        )
        selection_input =
          Hive::RefactorPatrol::DecisionProjection.candidate_input(
            job_id: aggregate.fetch("job_id"),
            phase: "discovery"
          )
        capture = Hive::Modules::Migration::PatrolCapture.build(
          module_name: "architecture-patrol",
          project: {
            "project_id" => entry.fetch("project_id"),
            "name" => entry.fetch("name"),
            "repository" => entry["repository_identity"]
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
            "job_id" => aggregate.fetch("job_id"),
            "window_started_at" => occurred_at.iso8601(6),
            "attempt_generation" => 1
          },
          owner: migration.fetch("owner"),
          owner_epoch: migration.fetch("epoch"),
          selection_input: selection_input,
          selection:
            Hive::Modules::Migration::PatrolDecisionProjection.build(
              module_name: "architecture-patrol",
              rationale: "due",
              job_id: aggregate.fetch("job_id"),
              phase: "discovery"
            ),
          outcome_class: nil,
          outcome: nil,
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

      def rollover(store:, entry:, aggregate:, now:,
                   claim_liveness_resolver: nil)
        occurrence = store.occurrence_for_job(
          aggregate.fetch("job_id")
        )
        unless occurrence && occurrence.fetch("phase") == "reserved"
          raise Hive::ConfigError,
                "architecture patrol current occurrence cannot roll"
        end
        provisional = Hive::Modules::Migration::PatrolCapture.from_h(
          occurrence.fetch("provisional_capture")
        )
        successor = successor_capture(provisional, now: now)
        return aggregate if @dry_run

        store.resolve_expired_discovery_for_rollover!(
          aggregate.fetch("job_id"),
          occurrence_id: provisional.occurrence_id,
          now: now,
          claim_liveness_resolver: claim_liveness_resolver
        )
        aggregate = store.read_job(aggregate.fetch("job_id"))
        store.assert_recorded_transitions_terminal!(aggregate)
        store.reserve_successor_occurrence!(
          aggregate.fetch("job_id"),
          predecessor: provisional,
          capture: successor,
          now: now
        )
        finalize_rollover_segment(
          store, entry, provisional, aggregate, now
        )
        store.rollover_occurrence!(
          aggregate.fetch("job_id"),
          from: provisional.occurrence_id,
          to: successor.occurrence_id,
          now: now
        )
        store.read_job(aggregate.fetch("job_id"))
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

      def recover(store:, entry:, now:)
        active = recovery_active_occurrences(store)
        if recover_pending_rollovers(store, entry, now, active)
          active = recovery_active_occurrences(store)
        end
        active.each do |occurrence|
          job_id = nil
          if occurrence.fetch("phase") == "reserved"
            job_id = recovery_job_id(occurrence)
            aggregate = store.read_job(job_id)
            unless aggregate.fetch("occurrence_id") ==
                   occurrence.fetch("occurrence_id")
              raise Hive::ConfigError,
                    "architecture patrol recovery occurrence does not match its job"
            end
            aggregate = yield(aggregate)
            if aggregate.fetch("complete")
              publish_recovered_finalization(
                store, entry, occurrence, aggregate, now
              )
              next
            end
          end

          if occurrence.fetch("outbox").any? do |outbox_entry|
            outbox_entry.fetch("acknowledged") == false
          end
            drain(store, entry, occurrence.fetch("occurrence_id"))
          end
        rescue RecoveryError
          raise
        rescue StandardError => e
          raise RecoveryError.new(
            error: e,
            occurrence_id: occurrence["occurrence_id"],
            job_id: job_id
          )
        end
      end

      private

      def recovery_active_occurrences(store)
        active = []
        store.each_recovery_active_occurrence do |occurrence|
          active << occurrence
        end
        active
      end

      def recover_pending_rollovers(store, entry, now, active)
        recovered = false
        active.each do |occurrence|
          job_id = nil
          begin
            next unless occurrence.fetch("phase") == "reserved"

            successor = Hive::Modules::Migration::PatrolCapture.from_h(
              occurrence.fetch("provisional_capture")
            )
            generation = successor.reservation["attempt_generation"]
            next unless generation.is_a?(Integer) && generation > 1

            job_id = recovery_job_id(occurrence)
            aggregate = store.read_job(job_id)
            next if aggregate.fetch("occurrence_id") ==
                    successor.occurrence_id

            predecessor = predecessor_capture(successor)
            unless aggregate.fetch("occurrence_id") ==
                   predecessor.occurrence_id
              next
            end

            store.assert_recorded_transitions_terminal!(aggregate)
            finalize_rollover_segment(
              store, entry, predecessor, aggregate, now
            )
            store.rollover_occurrence!(
              job_id,
              from: predecessor.occurrence_id,
              to: successor.occurrence_id,
              now: now
            )
            recovered = true
          rescue RecoveryError
            raise
          rescue StandardError => e
            raise RecoveryError.new(
              error: e,
              occurrence_id: occurrence["occurrence_id"],
              job_id: job_id
            )
          end
        end
        recovered
      end

      def canonical_time(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "architecture patrol occurrence time is malformed"
      end

      def successor_capture(capture, now:)
        generation = capture.reservation.fetch("attempt_generation")
        build_segment_capture(
          capture,
          reservation: capture.reservation.merge(
            "attempt_generation" => generation + 1
          ),
          recorded_at: now
        )
      rescue KeyError
        raise Hive::ConfigError,
              "architecture patrol occurrence generation is missing"
      end

      def predecessor_capture(capture)
        generation = capture.reservation.fetch("attempt_generation")
        unless generation.is_a?(Integer) && generation > 1
          raise Hive::ConfigError,
                "architecture patrol successor generation is malformed"
        end
        build_segment_capture(
          capture,
          reservation: capture.reservation.merge(
            "attempt_generation" => generation - 1
          ),
          recorded_at: capture.recorded_at
        )
      rescue KeyError
        raise Hive::ConfigError,
              "architecture patrol occurrence generation is missing"
      end

      def build_segment_capture(capture, reservation:, recorded_at:)
        Hive::Modules::Migration::PatrolCapture.build(
          module_name: capture.module_name,
          project: capture.project,
          trigger: capture.trigger,
          reservation: reservation,
          owner: capture.owner,
          owner_epoch: capture.owner_epoch,
          selection_input: capture.selection_input,
          selection: capture.selection,
          outcome_class: nil,
          outcome: nil,
          occurred_at: capture.occurred_at,
          recorded_at: recorded_at
        )
      end

      def finalize_rollover_segment(store, entry, provisional, aggregate,
                                    now)
        occurrence = store.occurrence(provisional.occurrence_id)
        if occurrence
          if occurrence.fetch("phase") == "reserved"
            capture = rollover_final_capture(
              store, provisional, aggregate, now
            )
            store.finalize_occurrence!(
              capture: capture, event: nil, now: now
            )
          end
          store.drain_occurrence_outbox!(
            provisional.occurrence_id,
            evidence_store: @evidence_store_factory.call(entry),
            project_entry: entry,
            kinds: %w[receipt capture]
          )
        end
        return if store.occurrence_terminalized?(provisional)

        raise Hive::ConfigError,
              "architecture patrol predecessor occurrence is not terminal"
      end

      def rollover_final_capture(store, provisional, aggregate, now)
        actions = aggregate.fetch("actions")
        outcome = {
          "rationale" => "effect_capacity_rollover",
          "job_id" => aggregate.fetch("job_id"),
          "state" => aggregate.fetch("state"),
          "complete" => false,
          "action_count" => actions.size,
          "action_outcomes" => actions.to_h do |action|
            [
              action.fetch("canonical_action_id"),
              action.fetch("outcome")
            ]
          end,
          "completion_status" => "rolled_over"
        }
        Hive::Modules::Migration::PatrolCapture.build(
          module_name: "architecture-patrol",
          project: provisional.project,
          trigger: provisional.trigger,
          reservation: provisional.reservation,
          owner: provisional.owner,
          owner_epoch: provisional.owner_epoch,
          selection_input: provisional.selection_input,
          selection: provisional.selection,
          outcome_class: "completed",
          outcome: outcome,
          effect_ids: store.terminal_effect_receipt_ids(
            provisional.occurrence_id
          ),
          occurred_at: provisional.occurred_at,
          recorded_at: now
        )
      end

      def assert_same_owner!(capture, migration)
        return if capture.owner == migration.fetch("owner") &&
                  capture.owner_epoch == migration.fetch("epoch")

        raise @reservation_error.new(
          "architecture_patrol_occurrence_owner_changed"
        )
      end

      def recovery_job_id(occurrence)
        capture = Hive::Modules::Migration::PatrolCapture.from_h(
          occurrence.fetch("provisional_capture")
        )
        reservation = capture.reservation
        unless reservation.fetch("kind") == "architecture"
          raise Hive::ConfigError,
                "architecture patrol recovery capture is not architecture work"
        end

        reservation.fetch("job_id")
      rescue KeyError => e
        raise Hive::ConfigError,
              "architecture patrol recovery capture is missing #{e.key.inspect}"
      end

      def publish_recovered_finalization(store, entry, occurrence, aggregate,
                                         now)
        provisional = Hive::Modules::Migration::PatrolCapture.from_h(
          occurrence.fetch("provisional_capture")
        )
        token = {
          job_id: aggregate.fetch("job_id"),
          registration: entry.fetch("name"),
          phase: aggregate.fetch("actions").empty? ? :discovery : :action,
          occurrence_id: provisional.occurrence_id,
          migration_owner: provisional.owner,
          migration_epoch: provisional.owner_epoch
        }
        publish_finalized(
          store: store,
          entry: entry,
          token: token,
          result: { status: :closed },
          aggregate: aggregate,
          now: now
        )
      end

      def final_capture(store, provisional, token:, result:, aggregate:, now:)
        actions = aggregate.fetch("actions")
        outcome = {
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
          selection_input: provisional.selection_input,
          selection: provisional.selection,
          outcome_class: "complete",
          outcome: outcome,
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
