require "test_helper"
require "hive/modules/migration/evidence_store"
require "hive/patrol/state_store"

class PatrolStateStoreEffectIntentsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_effect_intent_and_outcome_share_the_fingerprint_mapping
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      context = {
        "patch_id" => "patch-1",
        "head_sha" => "a" * 40
      }

      assert_equal :created, store.reserve_effect_intent(
        "fingerprint-1", intent, context: context, now: NOW
      )
      assert_equal :duplicate, store.reserve_effect_intent(
        "fingerprint-1", intent, context: context, now: NOW + 1
      )
      assert_equal "intent",
                   store.effect_intent_state("fingerprint-1", intent).fetch("status")

      store.record_effect_outcome(
        "fingerprint-1", intent,
        status: "committed",
        outcome: { "pr_url" => "https://github.com/owner/demo/pull/7" }
      )

      reloaded = Hive::Patrol::StateStore.new(root)
      state = reloaded.effect_intent_state("fingerprint-1", intent)
      assert_equal "committed", state.fetch("status")
      assert_equal(
        "https://github.com/owner/demo/pull/7",
        state.dig("outcome", "pr_url")
      )
      assert_equal(
        intent.to_h,
        reloaded.fingerprints
                .dig("fingerprint-1", "effect_intents", intent.intent_id, "intent")
      )
    end
  end

  def test_intent_identity_or_context_collision_fails_closed
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      store.reserve_effect_intent(
        "fingerprint-1", intent, context: { "patch_id" => "patch-1" }, now: NOW
      )

      assert_raises(Hive::ConfigError) do
        store.reserve_effect_intent(
          "fingerprint-1", intent,
          context: { "patch_id" => "different" },
          now: NOW + 1
        )
      end
    end
  end

  def test_configured_store_routes_state_finding_and_attempt_writes_through_gateway
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(root, "evidence")
      )
      store.configure_effect_gateway!(
        capture: capture,
        evidence_store: evidence,
        config_loader: ->(_path) { { "patrol" => { "enabled" => true } } },
        capability_checker: ->(**) { true }
      )
      finding = Struct.new(:id) do
        def to_h = { "id" => id, "title" => "Finding" }
      end.new("finding-1")
      patch = {
        "id" => "patch-1",
        "fingerprint" => "fingerprint-1",
        "passed" => true
      }

      store.update_state("last_run_at" => NOW.iso8601)
      store.write_finding(finding)
      perform_attempt(store, patch)
      receipt_count = evidence.receipts.size

      store.update_state("last_run_at" => NOW.iso8601)
      store.write_finding(finding)
      perform_attempt(store, patch)

      assert_equal receipt_count, evidence.receipts.size
      assert_equal %w[attempt finding state],
                   evidence.receipts.map { |receipt| receipt.intent.sink }.uniq.sort
      assert_equal(
        %w[committed known_not_sent],
        evidence.receipts.map(&:status).uniq.sort
      )
      assert_equal NOW.iso8601, store.state.fetch("last_run_at")
      assert_equal patch, store.read_json(
        File.join(store.root, "patches", "patch-1.json")
      ).except("patrol_occurrence_id")
    end
  end

  private

  def perform_attempt(store, patch)
    store.perform_cycle_effect!(
      sink: "attempt",
      target: "attempts/fingerprint-1",
      idempotency_key: "reservation-1:attempt:fingerprint-1",
      capability: "repository_write",
      reconcile: ->(_intent) { store.reconcile_attempt("fingerprint-1") }
    ) do
      store.write_patch("patch-1", patch)
      { "patch" => patch }
    end
  end

  def effect_intent
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "pull_request",
      target: "owner/demo:hive-patrol/fix",
      idempotency_key: "fingerprint-1:pr",
      capability: "github_pull_requests",
      created_at: NOW
    )
  end

  def capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "manual", "id" => "manual-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "due",
      decision: { "rationale" => "manual" },
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
