require "json"
require "digest"
require "time"
require "hive/modules/migration/patrol_evidence"
require "hive/refactor_patrol/effect_gateway"
require "hive/refactor_patrol/pr_manifest"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Product port for authoritative JobStore lifecycle mutations. It reuses
    # Architecture Patrol's single effect gateway and occurrence journal, so
    # local job/discovery/action transitions receive the same live admission,
    # sender CAS, uncertainty, and canonical receipt guarantees as remote
    # sinks without becoming a second recovery mechanism.
    class TransitionGateway
      attr_reader :capture

      class << self
        def capture_for_manifest(manifest:, project_id:, owner:, owner_epoch:,
                                 recorded_at: nil)
          data = Hive::RefactorPatrol::PrManifest.validate!(
            JSON.parse(JSON.generate(manifest))
          )
          source = data.fetch("source")
          occurred_at = Time.iso8601(source.fetch("merged_at"))
          recorded_at ||= occurred_at
          Hive::Modules::Migration::PatrolCapture.build(
            module_name: "architecture-patrol",
            project: {
              "project_id" => project_id.to_s,
              "name" => source.fetch("registration"),
              "repository" => source.fetch("repository")
            },
            trigger: {
              "kind" => "pull_request.merged",
              "id" => [
                source.fetch("repository"),
                source.fetch("number"),
                source.fetch("merge_sha")
              ].join(":"),
              "manifest_digest" => data.fetch("manifest_checksum"),
              "merge_sha" => source.fetch("merge_sha")
            },
            reservation: {
              "kind" => "architecture",
              "id" => data.fetch("job_id"),
              "job_id" => data.fetch("job_id")
            },
            owner: owner,
            owner_epoch: owner_epoch,
            decision_class: "provenance",
            decision: {
              "rationale" => "due",
              "job_id" => data.fetch("job_id"),
              "phase" => "discovery"
            },
            occurred_at: occurred_at,
            recorded_at: recorded_at
          )
        end
      end

      def initialize(project_root:, hive_state_path:, capture:, job_store:,
                     evidence_store:, config_loader:, module_execution: nil,
                     migration_lock: nil, ownership_loader: nil,
                     lifecycle_store_factory: nil, clock: -> { Time.now.utc },
                     claimant: nil, lease_sec: 300,
                     diagnostic_transition: false)
        @project_root = File.expand_path(project_root)
        @hive_state_path = File.expand_path(hive_state_path)
        @capture = capture
        @job_store = job_store
        @evidence_store = evidence_store
        @config_loader = config_loader
        @module_execution = module_execution
        @migration_lock = migration_lock
        @ownership_loader = ownership_loader
        @lifecycle_store_factory = lifecycle_store_factory
        @clock = clock
        @claimant = claimant
        @lease_sec = lease_sec
        @diagnostic_transition = diagnostic_transition == true
      end

      def perform!(sink:, target:, idempotency_key:, claim_generation: nil,
                   scope:, claim_validator:, reconcile:, replay:, &transition)
        raise ArgumentError, "a JobStore transition block is required" unless
          transition
        raise ArgumentError, "a JobStore replay reader is required" unless
          replay.respond_to?(:call)

        applied = false
        value = nil
        result = gateway(claim_validator).perform!(
          sink: sink,
          target: target,
          idempotency_key: idempotency_key,
          capability: "filesystem_write",
          claim_generation: claim_generation,
          scope: scope,
          reconcile: reconcile
        ) do
          value = transition.call
          if value.nil?
            raise Hive::RefactorPatrol::EffectGateway::NotDelivered,
                  "transition_not_applied"
          end
          applied = true
          {
            "transition_digest" => transition_digest(value)
          }
        end
        return value if applied

        replay.call(result)
      end

      private

      def gateway(claim_validator)
        options = {
          project_root: @project_root,
          hive_state_path: @hive_state_path,
          capture: @capture,
          authority: @capture.owner,
          evidence_store: @evidence_store,
          delivery_store: @job_store,
          claim_validator: claim_validator,
          config_loader: @config_loader,
          capability_checker: method(:capability_allowed?),
          module_execution: @module_execution,
          diagnostic_transition: @diagnostic_transition,
          clock: @clock,
          lease_sec: @lease_sec
        }
        options[:migration_lock] = @migration_lock if @migration_lock
        options[:ownership_loader] = @ownership_loader if @ownership_loader
        options[:lifecycle_store_factory] = @lifecycle_store_factory if
          @lifecycle_store_factory
        options[:claimant] = @claimant if @claimant
        Hive::RefactorPatrol::EffectGateway.new(**options)
      end

      def capability_allowed?(capability_context:, **)
        return true unless capability_context

        capability_context.require_filesystem_write!(
          ".hive-state/refactor_patrol/**"
        )
        true
      rescue Hive::Modules::CapabilityDenied
        false
      end

      def transition_digest(value)
        normalized = JSON.parse(JSON.generate(value))
        ::Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(normalized)
        )
      rescue JSON::GeneratorError, TypeError
        raise Hive::ConfigError,
              "architecture patrol transition result is not JSON serializable"
      end
    end
  end
end
