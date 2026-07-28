require "test_helper"
require "hive/patrol/effect_gateway"

class PatrolEffectGatewayTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_orders_intent_lock_live_authorization_sink_outcome_and_evidence
    with_tmp_dir do |root|
      operations = []
      domain = FakeDomain.new(operations)
      evidence = FakeEvidence.new(operations)
      gateway = gateway(
        root,
        domain: domain,
        evidence: evidence,
        operations: operations
      )

      result = gateway.perform!(
        sink: "finding",
        target: "finding-1",
        idempotency_key: "finding-1",
        capability: "filesystem_write"
      ) do
        operations << :sink
        { "finding_id" => "finding-1" }
      end

      assert_equal :committed, result.status
      assert_equal(
        [ :intent, :lock, :migration_reload, :config_reload, :capability_check,
         :sink, :outcome, :evidence ],
        operations
      )
      assert_equal "committed", domain.state.fetch("status")
    end
  end

  def test_capability_revoked_after_preflight_denies_without_sink
    with_tmp_dir do |root|
      operations = [ :preflight_allowed ]
      domain = FakeDomain.new(operations)
      evidence = FakeEvidence.new(operations)
      gateway = gateway(
        root,
        domain: domain,
        evidence: evidence,
        operations: operations,
        capability_allowed: false
      )
      calls = 0

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        gateway.perform!(
          sink: "pull_request",
          target: "owner/demo:branch",
          idempotency_key: "finding-1:pr",
          capability: "github_pull_requests"
        ) { calls += 1 }
      end

      assert_equal "capability_revoked", error.reason
      assert_equal 0, calls
      assert_equal "denied", domain.state.fetch("status")
      assert_equal "denied", evidence.receipts.last.status
    end
  end

  def test_duplicate_unknown_remote_effect_is_reconciliation_only
    with_tmp_dir do |root|
      operations = []
      domain = FakeDomain.new(operations, duplicate: true, status: "unknown")
      evidence = FakeEvidence.new(operations)
      reconciliations = 0
      sink_calls = 0
      gateway = gateway(
        root,
        domain: domain,
        evidence: evidence,
        operations: operations
      )

      result = gateway.perform!(
        sink: "pull_request",
        target: "owner/demo:branch",
        idempotency_key: "finding-1:pr",
        capability: "github_pull_requests",
        reconcile: lambda do |intent|
          reconciliations += 1
          assert_equal "owner/demo:branch", intent.target
          {
            "status" => "matched",
            "outcome" => { "pr_url" => "https://github.com/owner/demo/pull/7" }
          }
        end
      ) { sink_calls += 1 }

      assert_equal :reconciled, result.status
      assert_equal 1, reconciliations
      assert_equal 0, sink_calls
      assert_equal "reconciled", domain.state.fetch("status")
    end
  end

  def test_shadow_attempt_records_denial_without_domain_or_sink_mutation
    with_tmp_dir do |root|
      operations = []
      domain = FakeDomain.new(operations)
      evidence = FakeEvidence.new(operations)
      gateway = gateway(
        root,
        authority: "shadow",
        domain: domain,
        evidence: evidence,
        operations: operations
      )
      sink_calls = 0

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        gateway.perform!(
          sink: "issue",
          target: "owner/demo:family-1",
          idempotency_key: "family-1",
          capability: "github_issues"
        ) { sink_calls += 1 }
      end

      assert_equal "shadow_mutation_forbidden", error.reason
      assert_equal 0, sink_calls
      assert_empty domain.intents
      assert_nil domain.state
      assert_equal [ :lock, :migration_reload, :config_reload, :evidence ], operations
      assert_equal true, evidence.receipts.last.outcome.fetch("attempted")
    end
  end

  def test_stale_owner_epoch_is_denied
    with_tmp_dir do |root|
      operations = []
      domain = FakeDomain.new(operations)
      evidence = FakeEvidence.new(operations)
      gateway = gateway(
        root,
        domain: domain,
        evidence: evidence,
        operations: operations,
        owner_epoch: 2
      )

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        gateway.perform!(
          sink: "state",
          target: "patrol/state.json",
          idempotency_key: "occurrence-state",
          capability: "filesystem_write"
        ) { flunk "stale epoch must not reach the sink" }
      end

      assert_equal "stale_owner_epoch", error.reason
    end
  end

  private

  class FakeDomain
    attr_reader :intents, :state

    def initialize(operations, duplicate: false, status: "intent")
      @operations = operations
      @duplicate = duplicate
      @state = duplicate ? { "status" => status, "outcome" => {} } : nil
      @intents = []
    end

    def write_intent(intent)
      @operations << :intent
      @intents << intent
      return :duplicate if @duplicate

      @state = { "status" => "intent", "outcome" => {} }
      :created
    end

    def read(_intent) = @state

    def write_outcome(_intent, status:, outcome:)
      @operations << :outcome
      @state = { "status" => status, "outcome" => outcome }
    end
  end

  class FakeEvidence
    attr_reader :receipts

    def initialize(operations)
      @operations = operations
      @receipts = []
    end

    def append_receipt(receipt)
      @operations << :evidence
      @receipts << receipt
    end
  end

  def gateway(root, domain:, evidence:, operations:, authority: "legacy",
              capability_allowed: true, owner_epoch: 1)
    Hive::Patrol::EffectGateway.new(
      project_root: root,
      hive_state_path: File.join(root, ".hive-state"),
      capture: capture(authority),
      authority: authority,
      evidence_store: evidence,
      intent_writer: domain.method(:write_intent),
      recovery_reader: domain.method(:read),
      outcome_writer: domain.method(:write_outcome),
      migration_lock: lambda do |&block|
        operations << :lock
        block.call
      end,
      ownership_loader: lambda do
        operations << :migration_reload
        {
          "owner" => "legacy",
          "epoch" => owner_epoch,
          "admission" => true
        }
      end,
      config_loader: lambda do |_path|
        operations << :config_reload
        { "patrol" => { "enabled" => true } }
      end,
      capability_checker: lambda do |**|
        operations << :capability_check
        capability_allowed
      end,
      clock: -> { NOW }
    )
  end

  def capture(authority)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "schedule", "id" => "schedule-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: authority == "shadow" ? "legacy" : authority,
      owner_epoch: 1,
      decision_class: "due",
      decision: { "rationale" => "due" },
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
