require "digest"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/transition_gateway"

module Hive
  module RefactorPatrol
    # One intake protocol for immutable architecture manifests. Commands and
    # daemon catch-up provide policy/cadence; this collaborator owns occurrence
    # reservation, transition identity, and exact enqueue reconciliation.
    class ArchitectureIntakeTransitions
      def initialize(config_loader:, migration_snapshot: nil,
                     evidence_store_factory: nil, module_execution: nil,
                     admission_error: Hive::ConfigError,
                     gateway_factory: nil)
        @config_loader = config_loader
        @migration_snapshot = migration_snapshot || method(:migration_snapshot)
        @evidence_store_factory =
          evidence_store_factory || method(:evidence_store)
        @module_execution = module_execution
        @admission_error = admission_error
        @gateway_factory = gateway_factory ||
                           ->(**options) { TransitionGateway.new(**options) }
      end

      def enqueue(entry:, store:, manifest:, policy:, now:, dry_run: false,
                  required_occurrence_id: nil)
        unless !dry_run && gateway_supported?(store)
          return store.enqueue_manifest!(
            manifest,
            policy: policy,
            occurrence_id: dry_identity("occ", manifest),
            intake_transition_id: dry_identity("intent", manifest),
            now: now,
            dry_run: dry_run
          )
        end

        migration = current_migration_snapshot!(entry)
        capture = capture_for(
          entry, store, manifest, migration: migration, now: now
        )
        if required_occurrence_id &&
           capture.occurrence_id != required_occurrence_id
          raise Hive::ConfigError,
                "refactor patrol occurrence does not match command dispatch"
        end

        perform_enqueue!(
          entry, store, manifest, policy: policy, capture: capture,
          migration: migration, now: now
        )
      end

      private

      def gateway_supported?(store)
        store.respond_to?(:reserve_manifest_occurrence!) &&
          store.respond_to?(:prepare_effect!)
      end

      def capture_for(entry, store, manifest, migration:, now:)
        job_id = manifest.fetch("job_id")
        capture = existing_capture(store, job_id)
        capture ||= TransitionGateway.capture_for_manifest(
          manifest: manifest,
          project_id: entry["project_id"] ||
            "local-#{Digest::SHA256.hexdigest(entry.fetch("path"))}",
          owner: migration.fetch("owner"),
          owner_epoch: migration.fetch("epoch"),
          recorded_at: now
        )
        store.reserve_manifest_occurrence!(
          manifest, capture: capture, now: now
        )
        capture
      end

      def existing_capture(store, job_id)
        return unless store.respond_to?(:occurrence_capture)

        store.occurrence_capture(job_id)
      rescue JobStore::RecordNotFound
        nil
      end

      def perform_enqueue!(entry, store, manifest, policy:, capture:,
                           migration:, now:)
        job_id = manifest.fetch("job_id")
        source = manifest_source(manifest)
        gateway(entry, store, capture, now).perform!(
          sink: "job",
          target: job_id,
          idempotency_key: [
            job_id, "enqueue", manifest.fetch("manifest_checksum")
          ].join(":"),
          claim_generation: migration.fetch("epoch"),
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            reconcile_enqueue(store, job_id, source)
          end,
          replay: ->(_result) { store.read_job(job_id) }
        ) do |intent|
          store.enqueue_manifest!(
            manifest,
            policy: policy,
            occurrence_id: capture.occurrence_id,
            intake_transition_id: intent.intent_id,
            now: now
          )
        end
      end

      def gateway(entry, store, capture, now)
        @gateway_factory.call(
          project_root: entry.fetch("path"),
          hive_state_path: entry["hive_state_path"] ||
            File.join(entry.fetch("path"), ".hive-state"),
          capture: capture,
          job_store: store,
          evidence_store: @evidence_store_factory.call(entry),
          config_loader: @config_loader,
          module_execution: @module_execution,
          ownership_loader: -> { current_migration_snapshot!(entry) },
          clock: -> { now }
        )
      end

      def reconcile_enqueue(store, job_id, source)
        observed = store.read_job(job_id)
        if observed.fetch("source") == source
          {
            "status" => "matched",
            "outcome" => { "state" => observed.fetch("state") }
          }
        else
          { "status" => "ambiguous", "outcome" => {} }
        end
      rescue JobStore::RecordNotFound
        { "status" => "absent", "outcome" => {} }
      end

      def current_migration_snapshot!(entry)
        snapshot = @migration_snapshot.call(entry)
        valid = snapshot.is_a?(Hash) &&
                %w[legacy module].include?(snapshot["owner"]) &&
                snapshot["epoch"].to_i.positive? &&
                snapshot["admission"] == true
        raise @admission_error,
              "architecture patrol migration admission is unavailable" unless
          valid

        snapshot
      end

      def migration_snapshot(entry)
        Hive::Modules::Migration::Patrols.ownership_snapshot(
          entry.fetch("path"), "architecture-patrol",
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

      def manifest_source(manifest)
        manifest.fetch("source").merge(
          "changed_paths" => manifest.fetch("changed_paths"),
          "manifest_checksum" => manifest.fetch("manifest_checksum")
        )
      end

      def dry_identity(prefix, manifest)
        digest = Digest::SHA256.hexdigest(
          [
            prefix,
            manifest.fetch("job_id"),
            manifest.fetch("manifest_checksum")
          ].join(":")
        )
        "#{prefix}-#{digest}"
      end
    end
  end
end
