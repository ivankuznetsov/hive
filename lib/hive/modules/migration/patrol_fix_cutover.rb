require "hive/modules/migration/patrol_fix_epoch_port"
require "hive/modules/migration/patrol_fix_group_materializer"
require "hive/modules/migration/patrol_fix_source_authority"
require "hive/patrol/state_store"
require "hive/patrol_fix/migration/applier"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/migration/forward_recovery"
require "hive/refactor_patrol/canonical_action_catalog"
require "hive/refactor_patrol/job_store"

module Hive
  module Modules
    module Migration
      # Production composition root for one project-local Patrol-fix cutover.
      # It owns no extra epochs or outboxes; all ports reconstruct from the
      # existing project state after every process restart.
      class PatrolFixCutover
        attr_reader :state

        def initialize(project_root:, hive_state_path:, manifest:,
                       ordinary_store: nil, architecture_store: nil,
                       canonical_action_catalog: nil, epoch_port: nil,
                       group_materializer: nil, clock: -> { Time.now.utc })
          @project_root = File.expand_path(project_root)
          @hive_state_path = File.expand_path(hive_state_path)
          @manifest = manifest
          @clock = clock
          @state = Hive::PatrolFix::Migration::CutoverState.new(
            root: File.join(@hive_state_path, "patrol-fix", "migration")
          )
          ordinary_store ||= Hive::Patrol::StateStore.new(
            @project_root, hive_state_path: @hive_state_path
          )
          architecture_store ||= Hive::RefactorPatrol::JobStore.for_patrol_fix_migration(
            @project_root, hive_state_path: @hive_state_path
          )
          canonical_action_catalog ||= Hive::RefactorPatrol::CanonicalActionCatalog.new
          @source_authority = PatrolFixSourceAuthority.new(
            ordinary_store: ordinary_store,
            architecture_store: architecture_store,
            canonical_action_catalog: canonical_action_catalog,
            manifest: @manifest
          )
          @epoch_port = epoch_port || PatrolFixEpochPort.new(
            project_root: @project_root, hive_state_path: @hive_state_path,
            clock: @clock
          )
          @group_materializer = group_materializer || PatrolFixGroupMaterializer.new(
            project_root: @project_root, hive_state_path: @hive_state_path,
            manifest: @manifest, source_authority: @source_authority,
            clock: @clock
          )
        end

        def call
          applier.call
        end

        def rollback!
          Hive::PatrolFix::Migration::ForwardRecovery.new(
            state: state, epoch_port: @epoch_port, applier: applier,
            clock: @clock
          ).rollback!
        end

        private

        def applier
          Hive::PatrolFix::Migration::Applier.new(
            state: state, manifest: @manifest,
            inventory_port: -> { @source_authority.inventory },
            epoch_port: @epoch_port,
            group_materializer: ->(group) { @group_materializer.call(group) },
            source_acknowledger: lambda do |member, outcome|
              group = group_for(member)
              receipt = @source_authority.acknowledge(
                member, outcome, group: group, now: @clock.call
              )
              unless outcome["route"].to_s.start_with?("blocked_")
                @group_materializer.record_source_acknowledgement!(
                  member, task: outcome, receipt_id: receipt, now: @clock.call
                )
              end
              receipt
            end,
            authority_verifier: lambda do |manifest:, state:, inventory:|
              @source_authority.verify(
                manifest: manifest, state: state, inventory: inventory
              )
            end,
            clock: @clock
          )
        end

        def group_for(member)
          @manifest.to_h.fetch("semantic_groups").find do |group|
            group.fetch("members").include?(member)
          end || raise(Hive::ConfigError, "migration source has no semantic group")
        end
      end
    end
  end
end
