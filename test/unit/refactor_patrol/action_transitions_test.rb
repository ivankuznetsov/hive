require "test_helper"
require "hive/refactor_patrol/action_transitions"

class RefactorPatrolActionTransitionsTest < Minitest::Test
  Capture = Data.define(:owner_epoch)
  Intent = Data.define(
    :intent_id, :module_name, :occurrence_id, :owner_epoch, :sink, :target,
    :idempotency_key, :scope
  )
  INTENT_ID = "intent-#{'1' * 64}".freeze

  class Gateway
    attr_reader :options

    def initialize(&handler)
      @handler = handler
    end

    def perform!(**options, &transition)
      @options = options
      @handler.call(options, transition)
    end
  end

  class Store
    attr_accessor :aggregate, :planned, :stale
    attr_reader :calls

    def initialize
      @calls = []
      @planned = []
    end

    def prepare_effect!(*) = true
    def read_job(*) = aggregate
    def plan_actions(*) = planned
    def assert_recorded_transitions_terminal!(*) = true

    def next_diagnostic_episode(aggregate, kind)
      aggregate.fetch("attempts").filter_map do |attempt|
        attempt["generation"] if attempt["kind"] == kind
      end.max.to_i + 1
    end

    def assert_action_claim!(*)
      if stale
        raise Hive::RefactorPatrol::JobStore::StaleClaim,
              "stale"
      end

      true
    end

    def claim_action!(job_id, action_id, **options)
      calls << [ :claim, job_id, action_id, options ]
      {
        job_id: job_id,
        canonical_action_id: action_id,
        owner: options.fetch(:owner),
        generation: 1,
        continuation_only: false
      }
    end

    def finish_action!(token, **options)
      calls << [ :finish, token, options ]
      aggregate
    end

    def release_action!(token, **options)
      calls << [ :release, token, options ]
      aggregate
    end

    def initialize_actions!(job_id, **options)
      calls << [ :initialize, job_id, options ]
      aggregate
    end

    def reconcile_linked_action!(job_id, action_id, **options)
      calls << [ :reconcile_link, job_id, action_id, options ]
      aggregate
    end

    def record_patch_publication_attempt!(token, **options)
      calls << [ :record_patch, token, options ]
      aggregate
    end

    def record_creation_intent!(token, **options)
      calls << [ :record_intent, token, options ]
      aggregate
    end

    def record_action_receipt!(token, **options)
      calls << [ :record_receipt, token, options ]
      aggregate
    end

    def record_patch_receipt!(token, **options)
      calls << [ :record_patch_receipt, token, options ]
      aggregate
    end

    def record_publication_attempt_phase!(token, **options)
      calls << [ :record_publication_phase, token, options ]
      aggregate
    end

    def supersede_publication_attempt!(token, **options)
      calls << [ :supersede_publication, token, options ]
      aggregate
    end

    def record_fix_receipt!(token, **options)
      calls << [ :record_fix_receipt, token, options ]
      aggregate
    end

    def materialize_terminal_proof!(job_id, action_id, **options)
      calls << [ :materialize_terminal_proof, job_id, action_id, options ]
      aggregate
    end

    def block_actions!(job_id, **options)
      calls << [ :block, job_id, options ]
      aggregate
    end
  end

  def test_claim_reconciliation_distinguishes_owned_ambiguous_and_absent
    action = action_record
    aggregate = aggregate_with(action)
    store = Store.new

    store.aggregate = aggregate_with(
      action_record(
        claims: [
          claim_record(owner: "worker", state: "claimed")
        ],
        transitions: [ transition_record ]
      )
    )
    gateway = Gateway.new do |options, _transition|
      [
        options.fetch(:reconcile).call(intent),
        options.fetch(:replay).call(nil)
      ]
    end
    result = claims(store, gateway).claim(
      aggregate, action, authority: true, now: now
    )
    assert_equal "matched", result.fetch(0).fetch("status")
    assert_equal "worker", result.fetch(1).fetch(:owner)

    store.aggregate = aggregate_with(
      action_record(
        claims: [
          claim_record(owner: "other", state: "claimed")
        ]
      )
    )
    gateway = Gateway.new do |options, _transition|
      options.fetch(:reconcile).call(intent)
    end
    assert_equal(
      "ambiguous",
      claims(store, gateway)
        .claim(aggregate, action, authority: true, now: now)
        .fetch("status")
    )

    store.aggregate = aggregate_with(action_record)
    gateway = Gateway.new do |options, _transition|
      options.fetch(:reconcile).call(intent)
    end
    assert_equal(
      "absent",
      claims(store, gateway)
        .claim(aggregate, action, authority: true, now: now)
        .fetch("status")
    )
  end

  def test_settle_reconciliation_covers_terminal_release_and_claim_fences
    token = action_token
    store = Store.new
    gateway = Gateway.new do |options, _transition|
      options.fetch(:reconcile).call(intent)
    end
    coordinator = claims(store, gateway)

    store.aggregate = aggregate_with(
      action_record(
        terminal: true,
        outcome: "done",
        receipts: { "proof" => { "id" => 1 } },
        claims: [ claim_record ],
        transitions: [ transition_record ]
      )
    )
    assert_equal(
      "matched",
      coordinator.settle(
        token,
        outcome: "done",
        receipts: { "proof" => { "id" => 1 } },
        terminal: true,
        backoff_sec: 5,
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(claims: [ claim_record(state: "claimed") ])
    )
    assert_equal(
      "absent",
      coordinator.settle(
        token,
        outcome: "retry",
        receipts: {},
        terminal: false,
        backoff_sec: 5,
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(
        claims: [
          claim_record(state: "released", outcome: "retry")
        ],
        transitions: [ transition_record ]
      )
    )
    assert_equal(
      "matched",
      coordinator.settle(
        token,
        outcome: "retry",
        receipts: {},
        terminal: false,
        backoff_sec: 5,
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(
        claims: [
          claim_record(state: "released", outcome: "other")
        ]
      )
    )
    assert_equal(
      "ambiguous",
      coordinator.settle(
        token,
        outcome: "retry",
        receipts: {},
        terminal: false,
        backoff_sec: 5,
        now: now
      ).fetch("status")
    )

    store.stale = true
    refute action_context(store, gateway)
      .claim_validator(token, now).call
  end

  def test_claim_scoped_receipt_reconciliation_matches_each_namespace
    token = action_token
    patch = {
      "publication_base_sha" => "a" * 40,
      "commit_sha" => "b" * 40
    }
    attempt_id = Hive::RefactorPatrol::PublicationAttempt.id_for(
      publication_base_sha: patch.fetch("publication_base_sha"),
      commit_sha: patch.fetch("commit_sha")
    )
    payload = { "operation" => "create" }
    store = Store.new
    store.aggregate = aggregate_with(
      action_record(
        receipts: {
          "publication_attempts" => {
            attempt_id => { "descriptor" => {} }
          },
          "creation_intent" => { "payload" => payload },
          "push_complete" => payload
        },
        claims: [ claim_record ],
        transitions: [ transition_record ]
      )
    )
    gateway = Gateway.new do |options, _transition|
      options.fetch(:reconcile).call(intent)
    end
    coordinator = claims(store, gateway)

    assert_equal(
      "matched",
      coordinator.record_patch_publication(
        token, patch: patch, now: now
      ).fetch("status")
    )
    assert_equal(
      "matched",
      coordinator.record_creation_intent(
        token, "push_intent", payload, now: now
      ).fetch("status")
    )
    assert_equal(
      "matched",
      coordinator.record_action_receipt(
        token, "push_complete", payload, now: now
      ).fetch("status")
    )
    assert_equal(
      "matched",
      coordinator.record_patch_receipt(
        token, receipt: payload, now: now
      ).fetch("status")
    )
    assert_equal(
      "matched",
      coordinator.record_fix_receipt(
        token, receipt: payload, now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(claims: [ claim_record(state: "claimed") ])
    )
    assert_equal(
      "absent",
      coordinator.claimed_transition(
        token,
        operation: "custom",
        payload: payload,
        now: now
      ) { flunk("reconciliation must not send") }.fetch("status")
    )

    store.aggregate = aggregate_with(action_record)
    assert_equal(
      "ambiguous",
      coordinator.claimed_transition(
        token,
        operation: "custom",
        payload: payload,
        now: now
      ) { flunk("reconciliation must not send") }.fetch("status")
    )
  end

  def test_plan_link_and_block_reconciliation_are_exact
    store = Store.new
    store.planned = [ { "canonical_action_id" => "action-1" } ]
    gateway = Gateway.new do |options, _transition|
      options.fetch(:reconcile).call(intent)
    end
    coordinator = plan(store, gateway)

    store.aggregate = aggregate_with(
      action_record,
      attempts: [
        {
          "kind" =>
            Hive::RefactorPatrol::JobStore::JOB_TRANSITION_ATTEMPT_KIND,
          "operation" => "initialize-actions",
          "transitions" => [ transition_record ]
        }
      ]
    )
    assert_equal(
      "matched",
      coordinator.initialize_actions(
        aggregate_with,
        specifications: [],
        terminal_proofs: {},
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with
    assert_equal(
      "absent",
      coordinator.initialize_actions(
        aggregate_with,
        specifications: [],
        terminal_proofs: {},
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(action_id: "other")
    )
    assert_equal(
      "ambiguous",
      coordinator.initialize_actions(
        aggregate_with,
        specifications: [],
        terminal_proofs: {},
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(
        terminal: true,
        outcome: "linked",
        transitions: [ transition_record ]
      )
    )
    assert_equal(
      "matched",
      coordinator.reconcile_linked(
        aggregate_with,
        action_record,
        now: now
      ).fetch("status")
    )
    store.aggregate = aggregate_with(
      action_record(terminal: true, outcome: "linked")
    )
    assert_equal(
      "ambiguous",
      coordinator.reconcile_linked(
        aggregate_with,
        action_record,
        now: now
      ).fetch("status")
    )
    store.aggregate = aggregate_with(action_record)
    assert_equal(
      "absent",
      coordinator.reconcile_linked(
        aggregate_with,
        action_record,
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      action_record(transitions: [ transition_record ])
    )
    assert_equal(
      "matched",
      coordinator.materialize_terminal_proof(
        aggregate_with(action_record),
        "action-1",
        proof: { "kind" => "linked" },
        now: now
      ).fetch("status")
    )

    store.aggregate = aggregate_with(
      attempts: [
        {
          "kind" => "action_block",
          "generation" => 1,
          "reason" => "revoked",
          "evidence" => { "owner" => "other" },
          "transitions" => [ transition_record ]
        }
      ]
    )
    assert_equal(
      "matched",
      coordinator.block(
        aggregate_with,
        reason: "revoked",
        evidence: { "owner" => "other" },
        backoff_sec: 5,
        now: now
      ).fetch("status")
    )
    store.aggregate = aggregate_with
    assert_equal(
      "absent",
      coordinator.block(
        aggregate_with,
        reason: "revoked",
        evidence: {},
        backoff_sec: 5,
        now: now
      ).fetch("status")
    )
  end

  def test_replay_returns_the_current_aggregate_without_reapplying_mutations
    store = Store.new
    durable = aggregate_with(action_record(claims: [ claim_record ]))
    store.aggregate = durable
    replay_gateway = Gateway.new do |options, _transition|
      options.fetch(:replay).call(nil)
    end

    assert_same(
      durable,
      claims(store, replay_gateway).settle(
        action_token,
        outcome: "retry",
        receipts: {},
        terminal: false,
        backoff_sec: 5,
        now: now
      )
    )
    assert_same(
      durable,
      plan(store, replay_gateway).initialize_actions(
        aggregate_with,
        specifications: [],
        terminal_proofs: {},
        now: now
      )
    )
    assert_same(
      durable,
      plan(store, replay_gateway).reconcile_linked(
        aggregate_with(action_record),
        action_record,
        now: now
      )
    )
    assert_same(
      durable,
      plan(store, replay_gateway).materialize_terminal_proof(
        aggregate_with(action_record),
        "action-1",
        proof: { "kind" => "linked" },
        now: now
      )
    )
    assert_same(
      durable,
      plan(store, replay_gateway).block(
        aggregate_with,
        reason: "revoked",
        evidence: {},
        backoff_sec: 5,
        now: now
      )
    )
    assert_empty store.calls
  end

  def test_facade_delegates_patch_and_fix_receipts_to_claim_transitions
    calls = []
    claims = Object.new
    claims.define_singleton_method(:record_patch_receipt) do |*args, **options|
      calls << [ :patch, args, options ]
    end
    claims.define_singleton_method(:record_fix_receipt) do |*args, **options|
      calls << [ :fix, args, options ]
    end
    facade = Hive::RefactorPatrol::ActionTransitions.allocate
    facade.instance_variable_set(:@claims, claims)

    facade.record_patch_receipt(:token, receipt: { "id" => 1 }, now: now)
    facade.record_fix_receipt(:token, receipt: { "id" => 2 }, now: now)

    assert_equal(
      [
        [ :patch, [ :token ], { receipt: { "id" => 1 }, now: now } ],
        [ :fix, [ :token ], { receipt: { "id" => 2 }, now: now } ]
      ],
      calls
    )
  end

  private

  def claims(store, gateway)
    Hive::RefactorPatrol::ActionClaimTransitions.new(
      context: action_context(store, gateway),
      owner: "worker",
      owner_pid: 10,
      owner_process_start_time: "20",
      lease_sec: 30,
      claim_resolver: nil
    )
  end

  def plan(store, gateway)
    Hive::RefactorPatrol::ActionPlanTransitions.new(
      context: action_context(store, gateway)
    )
  end

  def action_context(store, gateway)
    Hive::RefactorPatrol::ActionTransitionContext.new(
      project_root: "/tmp/project",
      job_store: store,
      evidence_store: Object.new,
      capture: Capture.new(owner_epoch: 7),
      config_loader: ->(_root) { {} },
      module_execution: nil,
      clock: -> { now },
      owner: "worker",
      gateway_factory: ->(**) { gateway }
    )
  end

  def aggregate_with(action = nil, attempts: [])
    {
      "job_id" => "job-1",
      "state" => "actions",
      "actions" => action ? [ action ] : [],
      "attempts" => attempts
    }
  end

  def action_record(action_id: "action-1", claims: [], terminal: false,
                    outcome: nil, receipts: {}, transitions: [])
    {
      "canonical_action_id" => action_id,
      "claims" => claims,
      "terminal" => terminal,
      "outcome" => outcome,
      "receipts" => receipts,
      "transitions" => transitions
    }
  end

  def claim_record(owner: "worker", state: "claimed", outcome: nil)
    {
      "generation" => 1,
      "owner" => owner,
      "state" => state,
      "outcome" => outcome,
      "authority" => "owner"
    }
  end

  def action_token
    {
      job_id: "job-1",
      canonical_action_id: "action-1",
      generation: 1
    }
  end

  def transition_record
    {
      "intent_id" => INTENT_ID,
      "outcome" => "applied",
      "error_code" => nil
    }
  end

  def intent
    Intent.new(
      INTENT_ID,
      "architecture-patrol",
      "occ-#{'2' * 64}",
      7,
      "action",
      "job-1:action-1:operation",
      "job-1:action-1:operation:7",
      {
        "job_id" => "job-1",
        "canonical_action_id" => "action-1"
      }
    )
  end

  def now
    Time.utc(2026, 7, 28, 18)
  end
end
