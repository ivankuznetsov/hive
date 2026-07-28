require "digest"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/transition_gateway"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Shared gateway and canonical-state helpers for discovery transitions.
    # It owns dependencies, not transition decisions.
    class DiscoveryTransitionContext
      attr_reader :owner

      def initialize(config_loader:, migration_snapshot: nil,
                     evidence_store_factory: nil, module_execution:, owner:,
                     occurrence_lifecycle:, claimant: nil,
                     gateway_factory: nil)
        @config_loader = config_loader
        @migration_snapshot = migration_snapshot || method(:migration_snapshot)
        @evidence_store_factory =
          evidence_store_factory || method(:evidence_store)
        @module_execution = module_execution
        @owner = owner
        @occurrence_lifecycle = occurrence_lifecycle
        @claimant = claimant || "architecture-scheduler-#{owner}"
        @gateway_factory = gateway_factory ||
                           ->(**options) { TransitionGateway.new(**options) }
      end

      def gateway(entry, store, capture, now,
                  diagnostic_transition: false)
        unless capture
          raise JobStore::InconsistentRecord,
                "architecture patrol occurrence is unavailable"
        end

        @gateway_factory.call(
          project_root: entry.fetch("path"),
          hive_state_path: entry["hive_state_path"] ||
            File.join(entry.fetch("path"), ".hive-state"),
          capture: capture,
          job_store: store,
          evidence_store: @evidence_store_factory.call(entry),
          config_loader: @config_loader,
          module_execution: @module_execution,
          ownership_loader: lambda do
            @migration_snapshot.call(entry, "architecture-patrol")
          end,
          clock: -> { now },
          claimant: @claimant,
          diagnostic_transition: diagnostic_transition
        )
      end

      def gateway_supported?(store)
        store.respond_to?(:prepare_effect!) &&
          store.respond_to?(:occurrence_capture)
      end

      def claim_validator(store, token, now)
        lambda do |**|
          store.assert_discovery_claim!(token, now: now)
        rescue JobStore::StaleClaim
          false
        end
      end

      def discovery_attempt(aggregate, generation)
        aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == JobStore::DISCOVERY_ATTEMPT_KIND &&
            attempt["generation"] == generation
        end
      end

      def active_attempt?(attempt)
        attempt && JobStore::ACTIVE_CLAIM_STATES.include?(
          attempt["state"]
        )
      end

      def owned_active_attempt?(attempt)
        active_attempt?(attempt) && attempt.fetch("owner") == owner
      end

      def reserve_occurrence(entry, store, aggregate, now)
        migration = @migration_snapshot.call(
          entry, "architecture-patrol"
        )
        @occurrence_lifecycle.reserve(
          store: store,
          entry: entry,
          aggregate: aggregate,
          migration: migration,
          now: now
        )
      end

      def digest(value)
        Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        )
      end

      def matched(aggregate)
        {
          "status" => "matched",
          "outcome" => { "state" => aggregate.fetch("state") }
        }
      end

      def absent
        { "status" => "absent", "outcome" => {} }
      end

      def ambiguous
        { "status" => "ambiguous", "outcome" => {} }
      end

      private

      def migration_snapshot(entry, module_name)
        Hive::Modules::Migration::Patrols.ownership_snapshot(
          entry.fetch("path"), module_name,
          hive_state_path: entry["hive_state_path"]
        )
      end

      def evidence_store(entry)
        state = entry["hive_state_path"] ||
                File.join(entry.fetch("path"), ".hive-state")
        Hive::Modules::Migration::EvidenceStore.new(
          root: File.join(
            state, "module-runtime", "migration", "patrol-evidence"
          )
        )
      end
    end
  end
end
