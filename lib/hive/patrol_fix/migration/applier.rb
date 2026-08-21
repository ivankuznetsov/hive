require "digest"
require "hive/patrol_fix"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/migration/disposition_manifest"

module Hive
  module PatrolFix
    module Migration
      # Resumable, source-neutral application of one verified U8 manifest.
      # Every mutating source/task operation is an injected port; PatrolFix
      # owns checkpoint ordering and integrity, not either discovery store.
      class Applier
        BLOCKED_ROUTES = %w[
          blocked_artifact_conflict blocked_ownership_conflict
          blocked_remote_conflict blocked_semantic_decision
          blocked_semantic_evidence blocked_source
        ].freeze
        DEFERRED_LEGACY_ROUTES = %w[
          recover_publication resume_validate reuse_linked_successor
        ].freeze

        class Error < Hive::Error; end
        class StalePreflight < Error; end
        class Blocked < Error; end

        def initialize(state:, manifest:, inventory_port:, epoch_port:,
                       group_materializer:, source_acknowledger:,
                       authority_verifier:, failure_barrier: ->(_boundary, **) { },
                       clock: -> { Time.now.utc })
          @state = state
          @manifest = manifest
          @inventory_port = inventory_port
          @epoch_port = epoch_port
          @group_materializer = group_materializer
          @source_acknowledger = source_acknowledger
          @authority_verifier = authority_verifier
          @failure_barrier = failure_barrier
          @clock = clock
        end

        def call
          @manifest.verify!
          current = @state.read
          if current
            durable_manifest = @state.manifest
            if durable_manifest.canonical_bytes != @manifest.canonical_bytes &&
               pristine_preflight?(current)
              revalidate_inventory!
              current = @state.preflight!(
                manifest: @manifest, source_epochs: @epoch_port.snapshot,
                source_ownership: @epoch_port.ownership_snapshot,
                now: now
              )
              durable_manifest = @state.manifest
            elsif durable_manifest.canonical_bytes != @manifest.canonical_bytes
              raise StalePreflight,
                    "Patrol-fix migration caller manifest differs from durable manifest"
            end
            @manifest = durable_manifest
          else
            revalidate_inventory!
            current = @state.preflight!(
              manifest: @manifest, source_epochs: @epoch_port.snapshot,
              source_ownership: @epoch_port.ownership_snapshot,
              now: now
            )
            @manifest = @state.manifest
          end
          if current.fetch("status") == "preflight"
            deferred = @manifest.to_h.fetch("semantic_groups").find do |group|
              DEFERRED_LEGACY_ROUTES.include?(
                group.dig("canonical_decision", "route")
              )
            end
            if deferred
              raise Blocked,
                    "legacy #{deferred.dig('canonical_decision', 'route')} disposition " \
                    "requires explicit artifact reconciliation before cutover"
            end
            if @manifest.to_h.fetch("semantic_groups").any? do |group|
              group.dig("canonical_decision", "route") == "wait_live_claim"
            end
              raise Blocked,
                    "legacy source claim must drain before Patrol-fix epoch fence"
            end
            barrier(:before_epoch_fence)
            fenced = @epoch_port.fence!(
              expected: current.fetch("source_epochs"),
              ownership: current.fetch("source_ownership"),
              inventory_guard: method(:revalidate_inventory!)
            )
            current = @state.fence!(
              expected_source_epochs: current.fetch("source_epochs"),
              fenced_source_epochs: fenced, now: now
            )
            barrier(:after_epoch_fence)
          end
          if current.fetch("status") == "committed"
            activate_discovery!(current)
            return current
          end

          @state.start_applying!(now: now)
          @manifest.to_h.fetch("semantic_groups").sort_by do |group|
            group.fetch("group_id")
          end.each { |group| apply_group(group) }

          final_inventory = revalidate_inventory!
          proof = @authority_verifier.call(
            manifest: @manifest.to_h, state: @state.read,
            inventory: final_inventory
          )
          barrier(:before_commit)
          committed = @state.commit!(verification: proof, now: now)
          activate_discovery!(committed)
          committed
        end

        private

        def apply_group(group)
          group_id = group.fetch("group_id")
          progress = @state.read.dig("groups", group_id)
          return if progress&.fetch("status") == "complete"
          decision = group.fetch("canonical_decision")
          route = decision.fetch("route")
          intent = {
            "group_id" => group_id,
            "candidate_set_digest" => group.fetch("candidate_set_digest"),
            "route" => route,
            "canonical_identity" => decision["canonical_identity"],
            "members" => group.fetch("members")
          }
          @state.begin_group!(intent, now: now)
          if BLOCKED_ROUTES.include?(route)
            acknowledge_members(
              group_id, group.fetch("members"),
              { "route" => route, "canonical_identity" => decision["canonical_identity"] }
            )
            @state.complete_group!(group_id, now: now)
            return
          end
          if route == "wait_live_claim"
            raise Blocked, "legacy source claim must drain before Patrol-fix migration"
          end

          task = @state.group_task(group_id)
          unless task
            @state.arm_group_effect!(group_id, now: now)
            barrier(:before_group_materialization, group_id: group_id)
            task = @group_materializer.call(PatrolFix.deep_copy(group))
            @state.record_group_task!(group_id, task: task, now: now)
            barrier(:after_group_materialization, group_id: group_id)
          end
          acknowledge_members(group_id, group.fetch("members"), task)
          @state.complete_group!(group_id, now: now)
        end

        def acknowledge_members(group_id, members, outcome)
          acknowledged = @state.read.dig("groups", group_id, "acknowledgements")
          members.each do |member|
            next if acknowledged.key?(member)
            barrier(:before_source_acknowledgement, group_id: group_id, member: member)
            receipt = @source_acknowledger.call(
              member, PatrolFix.deep_copy(outcome)
            )
            @state.acknowledge_member!(
              group_id, member: member, receipt_id: receipt, now: now
            )
            barrier(:after_source_acknowledgement, group_id: group_id, member: member)
          end
        end

        def activate_discovery!(state)
          @epoch_port.activate_discovery!(
            expected: state.fetch("fenced_source_epochs"),
            ownership: state.fetch("source_ownership")
          )
        end

        def pristine_preflight?(state)
          state.fetch("status") == "preflight" && state.fetch("groups").empty? &&
            state.fetch("new_authority_effect") == false &&
            state.fetch("acknowledgement_count").zero?
        end

        def revalidate_inventory!
          current = @inventory_port.call
          expected = @manifest.to_h.fetch("inventory")
          candidate_root = DispositionManifest.inventory_root(
            current.fetch("candidates")
          )
          opaque = current.fetch("opaque_v3")
          valid = current.fetch("count") == expected.fetch("count") &&
            candidate_root == expected.fetch("root_digest") &&
            PatrolFix.canonical_json(current.fetch("candidates")) ==
              PatrolFix.canonical_json(expected.fetch("candidates")) &&
            opaque.fetch("count") == expected.dig("opaque_v3", "count") &&
            opaque.fetch("root_digest") == expected.dig("opaque_v3", "root_digest") &&
            PatrolFix.canonical_json(opaque.fetch("entries")) ==
              PatrolFix.canonical_json(expected.dig("opaque_v3", "entries"))
          raise StalePreflight, "Patrol-fix migration source inventory changed" unless valid
          current
        rescue KeyError, TypeError
          raise StalePreflight, "Patrol-fix migration source inventory is incomplete"
        end

        def barrier(boundary, **context)
          @failure_barrier.call(boundary, **context)
        end

        def now = @clock.call
      end
    end
  end
end
