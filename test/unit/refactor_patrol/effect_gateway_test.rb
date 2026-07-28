require "test_helper"
require "hive/refactor_patrol/effect_gateway"

class RefactorPatrolEffectGatewayTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_architecture_gateway_is_separate_and_denies_stale_claim
    assert_equal Object, Hive::RefactorPatrol::EffectGateway.superclass

    with_tmp_dir do |root|
      operations = []
      domain = Domain.new(operations)
      evidence = Evidence.new(operations)
      gateway = gateway(
        root,
        domain: domain,
        evidence: evidence,
        operations: operations,
        claim_valid: false
      )

      error = assert_raises(Hive::RefactorPatrol::EffectGateway::Denied) do
        gateway.perform!(
          sink: "pull_request",
          target: "owner/demo:branch",
          idempotency_key: "job-7:fix-1:pr",
          capability: "github_pull_requests",
          claim_generation: 4
        ) { flunk "a stale action claim must not reach the sink" }
      end

      assert_equal "stale_claim", error.reason
      assert_equal(
        [ :intent, :lock_enter, :migration_reload, :config_reload,
         :capability_check, :claim_check, :outcome, :evidence, :lock_exit ],
        operations
      )
    end
  end

  def test_unknown_effect_never_blindly_retries_when_reconciliation_is_ambiguous
    with_tmp_dir do |root|
      operations = []
      domain = Domain.new(operations, duplicate: true, status: "unknown")
      evidence = Evidence.new(operations)
      gateway = gateway(root, domain: domain, evidence: evidence, operations: operations)
      sink_calls = 0

      error = assert_raises(
        Hive::RefactorPatrol::EffectGateway::ReconciliationRequired
      ) do
        gateway.perform!(
          sink: "issue",
          target: "owner/demo:family-1",
          idempotency_key: "job-7:family-1:issue",
          capability: "github_issues",
          claim_generation: 4,
          reconcile: ->(_intent) { { "status" => "ambiguous", "outcome" => {} } }
        ) { sink_calls += 1 }
      end

      assert_equal "remote_identity_ambiguous", error.reason
      assert_equal 0, sink_calls
      assert_equal "unknown", domain.state.fetch("status")
    end
  end

  def test_exact_absence_converts_unknown_to_known_not_sent_before_one_sink_call
    with_tmp_dir do |root|
      operations = []
      domain = Domain.new(operations, duplicate: true, status: "unknown")
      evidence = Evidence.new(operations)
      gateway = gateway(root, domain: domain, evidence: evidence, operations: operations)
      sink_calls = 0

      result = gateway.perform!(
        sink: "issue",
        target: "owner/demo:family-1",
        idempotency_key: "job-7:family-1:issue",
        capability: "github_issues",
        claim_generation: 4,
        reconcile: ->(_intent) { { "status" => "absent", "outcome" => {} } }
      ) do
        sink_calls += 1
        { "issue_url" => "https://github.com/owner/demo/issues/7" }
      end

      assert_equal :committed, result.status
      assert_equal 1, sink_calls
      assert_equal "committed", domain.state.fetch("status")
      assert_equal %w[known_not_sent committed],
                   evidence.receipts.map(&:status)
    end
  end

  def test_split_authorization_defers_receipt_until_authoritative_outcome
    with_tmp_dir do |root|
      operations = []
      domain = Domain.new(operations)
      evidence = Evidence.new(operations)
      gateway = gateway(root, domain: domain, evidence: evidence, operations: operations)

      intent = gateway.authorize!(
        sink: "pull_request",
        target: "owner/demo:branch",
        idempotency_key: "job-7:fix-1:pr",
        capability: "github_pull_requests",
        claim_generation: 4
      )

      assert_instance_of Hive::Modules::Migration::EffectIntent, intent
      assert_empty evidence.receipts
      operations << :job_store_checkpoint
      receipt = gateway.finalize!(
        intent: intent,
        status: "committed",
        outcome: { "pr_url" => "https://github.com/owner/demo/pull/7" }
      )
      assert_equal "committed", receipt.status
      assert_equal :job_store_checkpoint, operations[-2]
      assert_equal :evidence, operations[-1]
    end
  end

  def test_split_apply_holds_migration_lock_across_the_external_sink
    with_tmp_dir do |root|
      operations = []
      domain = Domain.new(operations)
      evidence = Evidence.new(operations)
      gateway = gateway(root, domain: domain, evidence: evidence, operations: operations)

      value = gateway.apply!(
        sink: "pull_request",
        target: "owner/demo:branch",
        idempotency_key: "job-7:fix-1:pr",
        capability: "github_pull_requests",
        claim_generation: 4
      ) do |intent|
        operations << :external_sink
        assert_instance_of Hive::Modules::Migration::EffectIntent, intent
        "https://github.com/owner/demo/pull/7"
      end

      assert_equal "https://github.com/owner/demo/pull/7", value
      assert_equal(
        [ :intent, :lock_enter, :migration_reload, :config_reload,
         :capability_check, :claim_check, :external_sink, :lock_exit ],
        operations
      )
      assert_empty evidence.receipts
    end
  end

  private

  class Domain
    attr_reader :state

    def initialize(operations, duplicate: false, status: "intent")
      @operations = operations
      @duplicate = duplicate
      @state = duplicate ? { "status" => status, "outcome" => {} } : nil
    end

    def write_intent(_intent)
      @operations << :intent
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

  class Evidence
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

  def gateway(root, domain:, evidence:, operations:, claim_valid: true)
    Hive::RefactorPatrol::EffectGateway.new(
      project_root: root,
      hive_state_path: File.join(root, ".hive-state"),
      capture: capture,
      authority: "legacy",
      evidence_store: evidence,
      intent_writer: domain.method(:write_intent),
      recovery_reader: domain.method(:read),
      outcome_writer: domain.method(:write_outcome),
      migration_lock: lambda do |&block|
        operations << :lock_enter
        begin
          block.call
        ensure
          operations << :lock_exit
        end
      end,
      ownership_loader: lambda do
        operations << :migration_reload
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      end,
      config_loader: lambda do |_path|
        operations << :config_reload
        { "refactor_patrol" => { "enabled" => true } }
      end,
      capability_checker: lambda do |**|
        operations << :capability_check
        true
      end,
      claim_validator: lambda do |**|
        operations << :claim_check
        claim_valid
      end,
      clock: -> { NOW }
    )
  end

  def capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: {
        "kind" => "pull_request.merged",
        "id" => "owner/demo#7",
        "manifest_digest" => "a" * 64
      },
      reservation: { "kind" => "architecture", "id" => "job-7" },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "action",
      decision: { "rationale" => "due", "job_id" => "job-7" },
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
