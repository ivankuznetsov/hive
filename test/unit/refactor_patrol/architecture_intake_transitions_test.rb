require "test_helper"
require "hive/refactor_patrol/architecture_intake_transitions"

class RefactorPatrolArchitectureIntakeTransitionsTest < Minitest::Test
  NOW = Time.utc(2026, 7, 28, 15)
  AdmissionError = Class.new(StandardError)

  class Gateway
    attr_reader :constructor_options, :perform_options

    def initialize(**options)
      @constructor_options = options
    end

    def perform!(**options)
      @perform_options = options
      yield Struct.new(:intent_id).new("intent-#{'1' * 64}")
    end
  end

  class Store
    attr_accessor :capture, :aggregate, :read_failure
    attr_reader :reservations, :enqueues

    def initialize
      @reservations = []
      @enqueues = []
    end

    def prepare_effect!(*) = true

    def occurrence_capture(_job_id)
      return capture if capture

      raise Hive::RefactorPatrol::JobStore::RecordNotFound,
            "job is not enrolled yet"
    end

    def reserve_manifest_occurrence!(manifest, capture:, **options)
      self.capture = capture
      reservations << [ manifest, capture, options ]
    end

    def enqueue_manifest!(manifest, **options)
      enqueues << [ manifest, options ]
      self.aggregate ||= {
        "source" => source_for(manifest),
        "state" => "queued"
      }
    end

    def read_job(_job_id)
      if read_failure
        raise Hive::RefactorPatrol::JobStore::RecordNotFound,
              "missing"
      end

      aggregate
    end

    private

    def source_for(manifest)
      manifest.fetch("source").merge(
        "changed_paths" => manifest.fetch("changed_paths"),
        "manifest_checksum" => manifest.fetch("manifest_checksum")
      )
    end
  end

  def test_direct_fallback_preserves_dry_run_without_creating_recovery_state
    calls = []
    store = Object.new
    store.define_singleton_method(:enqueue_manifest!) do |manifest, **options|
      calls << [ manifest, options ]
      :direct
    end
    transitions = transitions_for

    assert_equal :direct,
                 transitions.enqueue(
                   entry: entry,
                   store: store,
                   manifest: manifest,
                   policy: { "epoch" => 1 },
                   now: NOW,
                   dry_run: true
                 )
    assert_equal true, calls.dig(0, 1, :dry_run)
  end

  def test_intake_reserves_once_and_exposes_exact_reconciliation
    gateways = []
    store = Store.new
    transitions = transitions_for(
      gateway_factory: lambda do |**options|
        Gateway.new(**options).tap { |gateway| gateways << gateway }
      end
    )

    result = transitions.enqueue(
      entry: entry,
      store: store,
      manifest: manifest,
      policy: { "epoch" => 1 },
      now: NOW
    )
    capture = store.capture
    assert_equal "architecture-patrol", capture.module_name
    assert_equal "github.com/owner/demo",
                 capture.project.fetch("repository")
    assert_equal "owner/demo:7:#{"b" * 40}",
                 capture.trigger.fetch("id")
    assert_equal capture.occurrence_id,
                 store.reservations.dig(0, 1).occurrence_id
    assert_equal "queued", result.fetch("state")
    gateway = gateways.fetch(0)
    refute gateway.constructor_options.key?(:claimant)
    assert_equal NOW, gateway.constructor_options.fetch(:clock).call
    assert_equal manifest.fetch("job_id"),
                 gateway.perform_options.fetch(:target)
    assert gateway.perform_options.fetch(:claim_validator).call
    assert_equal(
      "matched",
      gateway.perform_options.fetch(:reconcile).call(nil).fetch("status")
    )
    assert_equal result,
                 gateway.perform_options.fetch(:replay).call(nil)

    store.aggregate = result.merge(
      "source" => result.fetch("source").merge(
        "repository" => "other/demo"
      )
    )
    assert_equal(
      "ambiguous",
      gateway.perform_options.fetch(:reconcile).call(nil).fetch("status")
    )
    store.read_failure = true
    assert_equal(
      "absent",
      gateway.perform_options.fetch(:reconcile).call(nil).fetch("status")
    )
  end

  def test_existing_occurrence_is_reused_and_dispatch_identity_is_fenced
    store = Store.new
    first_gateway = nil
    transitions = transitions_for(
      gateway_factory: lambda do |**options|
        first_gateway = Gateway.new(**options)
      end
    )
    transitions.enqueue(
      entry: entry,
      store: store,
      manifest: manifest,
      policy: {},
      now: NOW
    )
    capture = store.capture
    store.aggregate = nil
    transitions.enqueue(
      entry: entry,
      store: store,
      manifest: manifest,
      policy: {},
      now: NOW,
      required_occurrence_id: capture.occurrence_id
    )
    assert_equal 2, store.reservations.size
    assert_equal capture.occurrence_id, store.capture.occurrence_id
    refute_nil first_gateway

    assert_raises(Hive::ConfigError) do
      transitions.enqueue(
        entry: entry,
        store: store,
        manifest: manifest,
        policy: {},
        now: NOW,
        required_occurrence_id: "occ-#{'f' * 64}"
      )
    end

    {
      "project_id" => "project-2",
      "name" => "other",
      "repository_identity" => "github.com/owner/other"
    }.each do |key, value|
      assert_raises(Hive::ConfigError) do
        transitions.enqueue(
          entry: entry.merge(key => value),
          store: store,
          manifest: manifest,
          policy: {},
          now: NOW
        )
      end
    end
    assert_equal 3, store.reservations.size
  end

  def test_invalid_migration_snapshot_uses_the_callers_typed_error
    transitions = transitions_for(
      migration_snapshot: ->(_entry) {
        { "owner" => "legacy", "epoch" => 0, "admission" => false }
      },
      admission_error: AdmissionError
    )

    error = assert_raises(AdmissionError) do
      transitions.enqueue(
        entry: entry,
        store: Store.new,
        manifest: manifest,
        policy: {},
        now: NOW
      )
    end
    assert_match(/migration admission is unavailable/, error.message)
  end

  private

  def transitions_for(migration_snapshot: nil,
                      admission_error: Hive::ConfigError,
                      gateway_factory: ->(**options) { Gateway.new(**options) })
    Hive::RefactorPatrol::ArchitectureIntakeTransitions.new(
      config_loader: ->(_path) { {} },
      migration_snapshot: migration_snapshot || ->(_entry) {
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      },
      evidence_store_factory: ->(_entry) { Object.new },
      admission_error: admission_error,
      gateway_factory: gateway_factory
    )
  end

  def entry
    {
      "project_id" => "project-1",
      "name" => "demo",
      "path" => "/repo",
      "hive_state_path" => "/repo/.hive-state",
      "repository_identity" => "github.com/owner/demo"
    }
  end

  def manifest
    @manifest ||= Hive::RefactorPatrol::PrManifest.build(
      source: {
        "url" => "https://github.com/owner/demo/pull/7",
        "number" => 7,
        "repository" => "owner/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => NOW.iso8601
      },
      files: [
        { "path" => "lib/demo.rb", "status" => "modified" }
      ]
    )
  end
end
