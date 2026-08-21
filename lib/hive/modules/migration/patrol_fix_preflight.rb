require "hive/patrol/state_store"
require "hive/patrol_fix/migration/disposition_manifest"
require "hive/patrol_fix/migration/inventory"
require "hive/patrol_fix/migration/reconciler"
require "hive/patrol_fix/migration/semantic_group"
require "hive/refactor_patrol/canonical_action_catalog"
require "hive/refactor_patrol/job_store"

module Hive
  module Modules
    module Migration
      # Read-only production composition for the U8 manifest consumed by U9.
      # Commands sees one service boundary and never constructs either source
      # authority directly.
      class PatrolFixPreflight
        def initialize(project_root:, hive_state_path:,
                       canonical_action_catalog: nil)
          @project_root = File.expand_path(project_root)
          @hive_state_path = File.expand_path(hive_state_path)
          @canonical_action_catalog = canonical_action_catalog ||
            Hive::RefactorPatrol::CanonicalActionCatalog.new
        end

        def call(semantic_decisions: [])
          ordinary = Hive::Patrol::StateStore.new(
            @project_root, hive_state_path: @hive_state_path
          )
          architecture = Hive::RefactorPatrol::JobStore.for_patrol_fix_migration(
            @project_root, hive_state_path: @hive_state_path
          )
          inventory = Hive::PatrolFix::Migration::Inventory.new(
            source_ports: [
              ordinary.patrol_fix_migration_inventory,
              architecture.patrol_fix_migration_inventory(
                canonical_action_catalog: @canonical_action_catalog
              )
            ]
          ).capture
          groups = Hive::PatrolFix::Migration::SemanticGroup.build(
            inventory.fetch("candidates"),
            semantic_decisions: semantic_decisions
          )
          reconciliation = Hive::PatrolFix::Migration::Reconciler.new.reconcile(
            groups: groups, candidates: inventory.fetch("candidates")
          )
          Hive::PatrolFix::Migration::DispositionManifest.build(
            inventory: inventory, reconciliation: reconciliation
          )
        end
      end
    end
  end
end
