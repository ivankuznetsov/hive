require "test_helper"
require "hive/refactor_patrol/effect_gateway"
require "hive/refactor_patrol/job_store"

class RefactorPatrolEffectGatewayTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_architecture_gateway_is_separate_and_denies_stale_claim
    assert_equal Object, Hive::RefactorPatrol::EffectGateway.superclass

    with_tmp_dir do |root|
      store, evidence = delivery(root)
      gateway = gateway(root, store: store, evidence: evidence,
                              claim_valid: false)

      error = assert_raises(Hive::RefactorPatrol::EffectGateway::Denied) do
        perform(gateway) do
          flunk "a stale action claim must not reach the sink"
        end
      end

      assert_equal "stale_claim", error.reason
      assert_equal [ "denied" ], evidence.receipts.map(&:status)
      assert_equal error.receipt.to_h, evidence.receipts.first.to_h
    end
  end

  def test_expired_uncertainty_requires_exact_reconciliation_and_never_blindly_retries
    with_tmp_dir do |root|
      store, evidence = delivery(root)
      first = gateway(
        root, store: store, evidence: evidence, lease_sec: 1,
        claimant: "sender-one"
      )
      sink_calls = 0

      assert_raises(RuntimeError) do
        perform(first) { raise "crash at the delivery boundary" }
      end

      second = gateway(
        root, store: store, evidence: evidence, now: NOW + 2,
        lease_sec: 1, claimant: "sender-two"
      )
      error = assert_raises(
        Hive::RefactorPatrol::EffectGateway::ReconciliationRequired
      ) do
        perform(
          second,
          reconcile: ->(_intent) {
            { "status" => "ambiguous", "outcome" => {} }
          }
        ) do
          sink_calls += 1
          { "issue_url" => "https://github.com/owner/demo/issues/7" }
        end
      end

      assert_equal "remote_identity_ambiguous", error.reason
      assert_equal 0, sink_calls
      assert_equal "dispatch_uncertain",
                   effect_state(store).fetch("state")
      assert_empty evidence.receipts
    end
  end

  def test_exact_absence_is_durable_before_one_fresh_sender_is_granted
    with_tmp_dir do |root|
      store, evidence = delivery(root)
      first = gateway(
        root, store: store, evidence: evidence, lease_sec: 1,
        claimant: "sender-one"
      )
      assert_raises(RuntimeError) do
        perform(first) { raise "crash before remote send" }
      end

      sink_calls = 0
      second = gateway(
        root, store: store, evidence: evidence, now: NOW + 2,
        lease_sec: 1, claimant: "sender-two"
      )
      result = perform(
        second,
        reconcile: ->(_intent) {
          { "status" => "absent", "outcome" => { "remote" => "absent" } }
        }
      ) do
        sink_calls += 1
        { "issue_url" => "https://github.com/owner/demo/issues/7" }
      end

      assert_equal :committed, result.status
      assert_equal 1, sink_calls
      assert_equal "committed", effect_state(store).fetch("state")
      assert_equal %w[known_not_sent committed],
                   evidence.receipts.map(&:status)
    end
  end

  def test_only_one_concurrent_sender_holds_the_per_intent_lease
    with_tmp_dir do |root|
      store, evidence = delivery(root)
      entered = Queue.new
      release = Queue.new
      first = gateway(
        root, store: store, evidence: evidence, claimant: "sender-one"
      )
      second = gateway(
        root, store: store, evidence: evidence, claimant: "sender-two"
      )
      first_result = nil
      worker = Thread.new do
        first_result = perform(first) do
          entered << true
          release.pop
          { "issue_url" => "https://github.com/owner/demo/issues/7" }
        end
      end
      entered.pop

      error = assert_raises(
        Hive::RefactorPatrol::EffectGateway::ReconciliationRequired
      ) do
        perform(second) { flunk "the second sender must not run" }
      end
      assert_equal "active_sender_lease", error.reason

      release << true
      worker.join
      assert_equal :committed, first_result.status
      assert_equal 1, evidence.receipts.size
    ensure
      release << true if worker&.alive?
      worker&.join
    end
  end

  def test_terminal_duplicate_returns_the_same_canonical_receipt_without_redelivery
    with_tmp_dir do |root|
      store, evidence = delivery(root)
      gateway = gateway(root, store: store, evidence: evidence)
      sink_calls = 0
      effect = lambda do |_intent|
        sink_calls += 1
        { "issue_url" => "https://github.com/owner/demo/issues/7" }
      end

      first = perform(gateway, &effect)
      duplicate = perform(gateway, &effect)

      assert_equal 1, sink_calls
      assert_equal first.receipt.to_h, duplicate.receipt.to_h
      assert_equal 1, evidence.receipts.size
      assert_equal first.receipt.to_h, evidence.receipts.first.to_h
    end
  end

  private

  class Evidence
    attr_reader :receipts

    def initialize
      @receipts = []
    end

    def append_receipt(receipt)
      existing = @receipts.find do |candidate|
        candidate.receipt_id == receipt.receipt_id
      end
      raise "receipt bytes conflict" if existing && existing.to_h != receipt.to_h

      @receipts << receipt unless existing
      receipt
    end
  end

  def delivery(root)
    store = Hive::RefactorPatrol::JobStore.new(root)
    store.write_job!(job)
    store.reserve_occurrence!("job-7", capture: capture, now: NOW)
    [ store, Evidence.new ]
  end

  def gateway(root, store:, evidence:, claim_valid: true, now: NOW,
              lease_sec: 300, claimant: "sender")
    Hive::RefactorPatrol::EffectGateway.new(
      project_root: root,
      hive_state_path: File.join(root, ".hive-state"),
      capture: capture,
      authority: "legacy",
      evidence_store: evidence,
      delivery_store: store,
      migration_lock: ->(&block) { block.call },
      ownership_loader: -> {
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      },
      config_loader: ->(_path) {
        { "refactor_patrol" => { "enabled" => true } }
      },
      capability_checker: ->(**) { true },
      claim_validator: ->(**) { claim_valid },
      clock: -> { now },
      lease_sec: lease_sec,
      claimant: claimant
    )
  end

  def perform(gateway, reconcile: nil, &effect)
    gateway.perform!(
      sink: "issue",
      target: "owner/demo:family-1",
      idempotency_key: "job-7:family-1:issue",
      capability: "github_issues",
      claim_generation: 4,
      scope: { "job_id" => "job-7" },
      reconcile: reconcile,
      &effect
    )
  end

  def effect_state(store)
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "architecture-patrol",
      occurrence_id: capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "issue",
      target: "owner/demo:family-1",
      idempotency_key: "job-7:family-1:issue",
      capability: "github_issues",
      claim_generation: 4,
      scope: { "job_id" => "job-7" },
      created_at: NOW
    )
    store.effect_state(intent)
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
      reservation: {
        "kind" => "architecture",
        "id" => "job-7",
        "job_id" => "job-7"
      },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "action",
      decision: { "rationale" => "due", "job_id" => "job-7" },
      occurred_at: NOW,
      recorded_at: NOW
    )
  end

  def job
    {
      "schema" => "hive-refactor-patrol-job",
      "schema_version" => 2,
      "job_id" => "job-7",
      "source" => {
        "url" => "https://github.com/owner/demo/pull/7",
        "number" => 7,
        "repository" => "owner/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40
      },
      "analysis_sha" => "c" * 40,
      "policy" => {
        "discovery" => true,
        "auto_fix" => false,
        "issue_filing" => false
      },
      "state" => "complete",
      "complete" => true,
      "dispositions" => {
        "accepted" => [],
        "flagged" => [],
        "suppressed" => []
      },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => "no_theses",
      "attempts" => [ { "number" => 1, "outcome" => "complete" } ],
      "actions" => [],
      "created_at" => NOW.iso8601,
      "updated_at" => NOW.iso8601
    }
  end
end
