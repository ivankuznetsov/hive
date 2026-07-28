require "test_helper"
require "hive/refactor_patrol/architecture_occurrence_lifecycle"
require "hive/refactor_patrol/discovery_transitions"

class RefactorPatrolDiscoveryTransitionsTest < Minitest::Test
  Capture = Data.define(:owner_epoch)
  ReservationError = Class.new(StandardError)

  class Gateway
    def initialize(&handler)
      @handler = handler
    end

    def perform!(**options, &transition)
      @handler.call(options, transition)
    end
  end

  class Store
    attr_accessor :aggregate, :capture, :claim_result, :stale, :occurrence,
                  :pending_occurrences, :terminal_receipts
    attr_reader :calls

    def initialize
      @calls = []
      @claim_result = {
        job_id: "job-1",
        owner: "worker",
        generation: 1
      }
      @pending_occurrences = []
      @terminal_receipts = []
    end

    def prepare_effect!(*) = true
    def read_job(*) = aggregate
    def occurrence_capture(*) = capture

    def assert_discovery_claim!(*)
      if stale
        raise Hive::RefactorPatrol::JobStore::StaleClaim,
              "stale"
      end

      true
    end

    def claim_discovery!(job_id, **options)
      calls << [ :claim, job_id, options ]
      claim_result
    end

    def release_discovery!(token, **options)
      calls << [ :release, token, options ]
      aggregate
    end

    def checkpoint_discovery!(token, **options)
      calls << [ :checkpoint, token, options ]
      aggregate
    end

    def checkpoint_discovery_progress!(token, **options)
      calls << [ :checkpoint_progress, token, options ]
      aggregate
    end

    def block_discovery!(job_id, **options)
      calls << [ :block_discovery, job_id, options ]
      aggregate
    end

    def block_actions!(job_id, **options)
      calls << [ :block_actions, job_id, options ]
      aggregate
    end

    def reserve_occurrence!(job_id, capture:, **options)
      calls << [ :reserve_occurrence, job_id, capture, options ]
      self.capture = capture
    end

    def occurrence_for_job(*) = occurrence
    def terminal_effect_receipt_ids(*) = terminal_receipts
    def projection_pending_occurrences = pending_occurrences

    def finalize_occurrence!(**options)
      calls << [ :finalize_occurrence, options ]
      options
    end

    def drain_occurrence_outbox!(occurrence_id, **options)
      calls << [ :drain_occurrence, occurrence_id, options ]
      true
    end
  end

  class OccurrenceLifecycle
    attr_reader :calls

    def initialize(capture)
      @capture = capture
      @calls = []
    end

    def reserve(**options)
      calls << options
      @capture
    end
  end

  class EventPublisher
    attr_reader :calls

    def initialize
      @calls = []
    end

    def prepare_architecture_patrol_finalized(entry, capture, **options)
      calls << [ entry, capture, options ]
      { "event_id" => "event-1" }
    end
  end

  def test_claim_reconciliation_and_expired_claim_resolution
    store = Store.new
    aggregate = aggregate_with
    store.aggregate = aggregate_with(
      attempts: [
        attempt(owner: "worker", state: "claimed")
      ]
    )
    gateway = reconcile_gateway
    result = claims(store, gateway).claim(
      entry: entry,
      store: store,
      capture: Capture.new(owner_epoch: 7),
      aggregate: aggregate,
      analysis_sha: "a" * 40,
      now: now
    )
    assert_equal "matched", result.fetch("status")

    store.aggregate = aggregate_with(
      attempts: [
        attempt(owner: "other", state: "claimed")
      ]
    )
    result = claims(store, reconcile_gateway).claim(
      entry: entry,
      store: store,
      capture: Capture.new(owner_epoch: 7),
      aggregate: aggregate,
      analysis_sha: "a" * 40,
      now: now
    )
    assert_equal "ambiguous", result.fetch("status")

    store.aggregate = aggregate_with
    result = claims(store, reconcile_gateway).claim(
      entry: entry,
      store: store,
      capture: Capture.new(owner_epoch: 7),
      aggregate: aggregate,
      analysis_sha: "a" * 40,
      now: now
    )
    assert_equal "absent", result.fetch("status")

    expired = aggregate_with(
      attempts: [
        attempt(expires_at: (now - 1).iso8601)
      ]
    )
    sending = Gateway.new do |_options, transition|
      transition.call
    end
    result = claims(
      store, sending, claim_resolver: ->(_claim) { :resolved }
    ).claim(
      entry: entry,
      store: store,
      capture: Capture.new(owner_epoch: 7),
      aggregate: expired,
      analysis_sha: "a" * 40,
      now: now
    )
    assert_equal "worker", result.fetch(:owner)

    unresolved = claims(
      store,
      sending,
      claim_resolver: ->(_claim) { raise "unavailable" }
    ).claim(
      entry: entry,
      store: store,
      capture: Capture.new(owner_epoch: 7),
      aggregate: expired,
      analysis_sha: "a" * 40,
      now: now
    )
    assert_nil unresolved

    store.claim_result = nil
    assert_raises(ReservationError) do
      claims(
        store, sending, claim_resolver: ->(_claim) { :resolved }
      ).claim(
        entry: entry,
        store: store,
        capture: Capture.new(owner_epoch: 7),
        aggregate: expired,
        analysis_sha: "a" * 40,
        now: now
      )
    end
  end

  def test_release_and_checkpoint_reconciliation_are_exact
    token = { job_id: "job-1", generation: 1 }
    store = Store.new
    store.capture = Capture.new(owner_epoch: 7)

    store.aggregate = aggregate_with(
      attempts: [
        attempt(state: "released", outcome: "retry")
      ]
    )
    assert_equal(
      "matched",
      claims(store, reconcile_gateway).release(
        entry: entry,
        store: store,
        token: token,
        reason: "retry",
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [ attempt(state: "claimed") ]
    )
    assert_equal(
      "absent",
      claims(store, reconcile_gateway).release(
        entry: entry,
        store: store,
        token: token,
        reason: "retry",
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [
        attempt(state: "released", outcome: "other")
      ]
    )
    assert_equal(
      "ambiguous",
      claims(store, reconcile_gateway).release(
        entry: entry,
        store: store,
        token: token,
        reason: "retry",
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    complete = envelope(complete: true)
    store.aggregate = aggregate_with(
      complete: true,
      attempts: [
        attempt(state: "complete", outcome: "complete")
      ]
    )
    assert_equal(
      "matched",
      claims(store, reconcile_gateway).checkpoint(
        entry: entry,
        store: store,
        token: token,
        envelope: complete,
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    partial = envelope(complete: false)
    store.aggregate = aggregate_with(
      attempts: [
        attempt(state: "released", outcome: "partial_review")
      ]
    )
    assert_equal(
      "matched",
      claims(store, reconcile_gateway).checkpoint(
        entry: entry,
        store: store,
        token: token,
        envelope: partial,
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [ attempt(state: "claimed") ]
    )
    assert_equal(
      "absent",
      claims(store, reconcile_gateway).checkpoint(
        entry: entry,
        store: store,
        token: token,
        envelope: {},
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [ attempt(state: "released", outcome: "other") ]
    )
    assert_equal(
      "ambiguous",
      claims(store, reconcile_gateway).checkpoint(
        entry: entry,
        store: store,
        token: token,
        envelope: partial,
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    store.stale = true
    refute discovery_context(
      store, reconcile_gateway
    ).claim_validator(store, token, now).call
  end

  def test_progress_checkpoint_reconciliation_and_receipt_replay
    token = { job_id: "job-1", generation: 1 }
    envelope = { "feature_results" => [ { "feature_id" => "one" } ] }
    store = Store.new
    store.capture = Capture.new(owner_epoch: 7)
    store.aggregate = aggregate_with(
      attempts: [ attempt(state: "claimed") ]
    ).merge("feature_results" => envelope.fetch("feature_results"))

    transitions = Hive::RefactorPatrol::DiscoveryTransitions.new(
      config_loader: ->(_root) { {} },
      migration_snapshot: ->(_entry, _module_name) {
        { "owner" => "legacy", "epoch" => 7 }
      },
      evidence_store_factory: ->(_entry) { Object.new },
      module_execution: nil,
      owner: "worker",
      owner_pid: 10,
      owner_process_start_time: "20",
      lease_sec: 30,
      claim_resolver: ->(_claim) { :unresolved },
      reservation_error: ReservationError,
      occurrence_lifecycle: OccurrenceLifecycle.new(store.capture),
      gateway_factory: ->(**) { reconcile_gateway }
    )
    context = discovery_context(store, reconcile_gateway)
    claims = Hive::RefactorPatrol::DiscoveryClaimTransitions.new(
      context: context,
      owner_pid: 10,
      owner_process_start_time: "20",
      lease_sec: 30,
      claim_resolver: ->(_claim) { :unresolved },
      reservation_error: ReservationError,
      claim_operation: "manual-discovery-claim",
      operation_prefix: ""
    )

    assert_equal(
      "matched",
      transitions.checkpoint_progress(
        entry: entry,
        store: store,
        token: token,
        envelope: envelope,
        now: now,
        lease_sec: 60
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [
        {
          "kind" => "discovery_block",
          "reason" => "disabled",
          "evidence" => {}
        }
      ]
    )
    assert_equal(
      "matched",
      transitions.block(
        entry: entry,
        store: store,
        aggregate: aggregate_with,
        phase: :discovery,
        reason: "disabled",
        evidence: {},
        now: now,
        backoff_sec: 5
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [ attempt(state: "claimed") ]
    ).merge("feature_results" => [])
    assert_equal(
      "absent",
      claims.checkpoint_progress(
        entry: entry,
        store: store,
        token: token,
        envelope: envelope,
        now: now,
        lease_sec: 60
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [ attempt(state: "released") ]
    )
    assert_equal(
      "ambiguous",
      claims.checkpoint_progress(
        entry: entry,
        store: store,
        token: token,
        envelope: envelope,
        now: now,
        lease_sec: 60
      ).fetch("status")
    )

    store.capture = nil
    claims.checkpoint_progress(
      entry: entry,
      store: store,
      token: token,
      envelope: envelope,
      now: now,
      lease_sec: 60
    )
    assert_equal :checkpoint_progress, store.calls.last.fetch(0)

    store.capture = Capture.new(owner_epoch: 7)
    store.aggregate = aggregate_with(
      attempts: [ attempt(owner: "worker", state: "claimed") ]
    )
    replay = Gateway.new do |options, _transition|
      options.fetch(:replay).call(nil)
    end
    token_result = claims(store, replay).claim(
      entry: entry,
      store: store,
      capture: store.capture,
      aggregate: aggregate_with,
      analysis_sha: "a" * 40,
      now: now
    )
    assert_equal "worker", token_result.fetch(:owner)

    claims(store, replay).release(
      entry: entry,
      store: store,
      token: token,
      reason: "retry",
      now: now,
      backoff_sec: 5
    )
    claims(store, replay).checkpoint(
      entry: entry,
      store: store,
      token: token,
      envelope: envelope(complete: true),
      now: now,
      backoff_sec: 5
    )
    claims(store, replay).checkpoint_progress(
      entry: entry,
      store: store,
      token: token,
      envelope: envelope,
      now: now,
      lease_sec: 60
    )
  end

  def test_diagnostic_block_reconciles_and_reserves_missing_occurrence
    store = Store.new
    store.aggregate = aggregate_with(
      attempts: [
        {
          "kind" => "discovery_block",
          "reason" => "disabled",
          "evidence" => { "config" => false }
        }
      ]
    )
    coordinator, lifecycle = blocks(store, reconcile_gateway)
    result = coordinator.block(
      entry: entry,
      store: store,
      aggregate: aggregate_with,
      phase: :discovery,
      reason: "disabled",
      evidence: { "config" => false },
      now: now,
      backoff_sec: 5
    )
    assert_equal "matched", result.fetch("status")
    assert_equal 1, lifecycle.calls.size

    store.capture = Capture.new(owner_epoch: 7)
    store.aggregate = aggregate_with
    coordinator, = blocks(store, reconcile_gateway)
    result = coordinator.block(
      entry: entry,
      store: store,
      aggregate: aggregate_with,
      phase: :action,
      reason: "disabled",
      evidence: {},
      now: now,
      backoff_sec: 5
    )
    assert_equal "absent", result.fetch("status")

    context = discovery_context(
      store,
      reconcile_gateway,
      capture: nil
    )
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      context.gateway(entry, store, nil, now)
    end
  end

  def test_occurrence_lifecycle_reserves_finalizes_and_recovers_projections
    store = Store.new
    publisher = EventPublisher.new
    lifecycle = Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle.new(
      migration_authority: :legacy,
      dry_run: false,
      evidence_store_factory: ->(_entry) { :evidence },
      event_publisher: publisher,
      module_schedule: "0 0 * * *",
      reservation_error: ReservationError
    )
    aggregate = architecture_aggregate
    migration = { "owner" => "legacy", "epoch" => 7 }

    capture = lifecycle.reserve(
      store: store,
      entry: architecture_entry,
      aggregate: aggregate,
      migration: migration,
      now: now
    )
    assert_equal "architecture-patrol", capture.module_name
    assert_equal :reserve_occurrence, store.calls.last.fetch(0)

    assert_same capture, lifecycle.reserve(
      store: store,
      entry: architecture_entry,
      aggregate: aggregate,
      migration: migration,
      now: now
    )
    assert_raises(ReservationError) do
      lifecycle.reserve(
        store: store,
        entry: architecture_entry,
        aggregate: aggregate,
        migration: { "owner" => "module", "epoch" => 8 },
        now: now
      )
    end

    store.occurrence = {
      "phase" => "reserved",
      "provisional_capture" => capture.to_h
    }
    token = {
      job_id: "job-1",
      occurrence_id: capture.occurrence_id,
      migration_epoch: 7,
      phase: :action
    }
    lifecycle.publish_finalized(
      store: store,
      entry: architecture_entry,
      token: token,
      result: { status: :closed },
      aggregate: aggregate.merge(
        "complete" => true,
        "actions" => [
          {
            "canonical_action_id" => "action-1",
            "outcome" => "done"
          }
        ]
      ),
      now: now
    )
    finalized = store.calls.find do |call|
      call.fetch(0) == :finalize_occurrence
    end.fetch(1).fetch(:capture)
    assert_equal(
      { "action-1" => "done" },
      finalized.decision.fetch("action_outcomes")
    )
    assert_equal "actions",
                 publisher.calls.last.fetch(2).fetch(:target_hook)

    store.occurrence = {
      "phase" => "finalized",
      "occurrence_id" => capture.occurrence_id
    }
    lifecycle.publish_finalized(
      store: store,
      entry: architecture_entry,
      token: token,
      result: { status: :closed },
      aggregate: aggregate.merge("complete" => true),
      now: now
    )
    assert_equal :drain_occurrence, store.calls.last.fetch(0)

    store.pending_occurrences = [
      { "occurrence_id" => capture.occurrence_id }
    ]
    lifecycle.recover(store: store, entry: architecture_entry)
    assert_equal :drain_occurrence, store.calls.last.fetch(0)
  end

  def test_diagnostic_block_replay_returns_the_current_aggregate
    store = Store.new
    store.capture = Capture.new(owner_epoch: 7)
    durable = aggregate_with
    store.aggregate = durable
    replay_gateway = Gateway.new do |options, _transition|
      options.fetch(:replay).call(nil)
    end
    coordinator, = blocks(store, replay_gateway)

    result = coordinator.block(
      entry: entry,
      store: store,
      aggregate: aggregate_with,
      phase: :discovery,
      reason: "disabled",
      evidence: {},
      now: now,
      backoff_sec: 5
    )

    assert_same durable, result
    assert_empty store.calls
  end

  private

  def claims(store, gateway,
             claim_resolver: ->(_claim) { :unresolved })
    Hive::RefactorPatrol::DiscoveryClaimTransitions.new(
      context: discovery_context(store, gateway),
      owner_pid: 10,
      owner_process_start_time: "20",
      lease_sec: 30,
      claim_resolver: claim_resolver,
      reservation_error: ReservationError
    )
  end

  def blocks(store, gateway)
    lifecycle = OccurrenceLifecycle.new(
      Capture.new(owner_epoch: 7)
    )
    context = discovery_context(
      store, gateway, lifecycle: lifecycle
    )
    [
      Hive::RefactorPatrol::DiscoveryBlockTransitions.new(
        context: context
      ),
      lifecycle
    ]
  end

  def discovery_context(store, gateway, lifecycle: nil, capture: :unused)
    lifecycle ||= OccurrenceLifecycle.new(
      Capture.new(owner_epoch: 7)
    )
    Hive::RefactorPatrol::DiscoveryTransitionContext.new(
      config_loader: ->(_root) { {} },
      migration_snapshot: lambda do |_entry, _module_name|
        { "owner" => "legacy", "epoch" => 7 }
      end,
      evidence_store_factory: ->(_entry) { Object.new },
      module_execution: nil,
      owner: "worker",
      occurrence_lifecycle: lifecycle,
      gateway_factory: ->(**) { gateway }
    )
  end

  def reconcile_gateway
    Gateway.new do |options, _transition|
      options.fetch(:reconcile).call(nil)
    end
  end

  def aggregate_with(attempts: [], complete: false)
    {
      "job_id" => "job-1",
      "state" => "reviewing",
      "complete" => complete,
      "attempts" => attempts,
      "feature_results" => [],
      "dispositions" => {
        "accepted" => [],
        "flagged" => [],
        "suppressed" => []
      }
    }
  end

  def attempt(owner: "worker", state: "claimed", outcome: nil,
              expires_at: (now + 60).iso8601)
    {
      "kind" =>
        Hive::RefactorPatrol::JobStore::DISCOVERY_ATTEMPT_KIND,
      "generation" => 1,
      "owner" => owner,
      "state" => state,
      "outcome" => outcome,
      "expires_at" => expires_at
    }
  end

  def envelope(complete:)
    {
      "complete" => complete,
      "feature_results" => [],
      "accepted" => [],
      "flagged" => [],
      "suppressed" => []
    }
  end

  def entry
    {
      "name" => "demo",
      "path" => "/tmp/demo",
      "hive_state_path" => "/tmp/demo/.hive-state"
    }
  end

  def architecture_entry
    entry.merge("project_id" => "project-1")
  end

  def architecture_aggregate
    {
      "job_id" => "job-1",
      "state" => "reviewing",
      "complete" => false,
      "zero_reason" => nil,
      "created_at" => now.iso8601,
      "actions" => [],
      "source" => {
        "repository" => "owner/repo",
        "number" => 42,
        "merge_sha" => "a" * 40,
        "manifest_checksum" => "b" * 64,
        "merged_at" => now.iso8601
      }
    }
  end

  def now
    Time.utc(2026, 7, 28, 18)
  end
end
