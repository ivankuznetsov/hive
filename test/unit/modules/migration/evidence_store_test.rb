require "test_helper"
require "hive/modules/migration/evidence_store"

class ModulesMigrationEvidenceStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_store_is_append_only_idempotent_and_restart_safe
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      intent = intent_for
      receipt = Hive::Modules::Migration::EffectReceipt.build(
        intent: intent,
        status: "committed",
        outcome: { "state" => "open", "remote_id" => "owner/demo#7" },
        recorded_at: NOW + 1
      )

      assert_equal :created, store.append_capture(capture).status
      assert_equal :duplicate, store.append_capture(capture).status
      assert_equal :created, store.append_receipt(receipt).status
      assert_equal :duplicate, store.append_receipt(receipt).status

      restarted = Hive::Modules::Migration::EvidenceStore.new(root: root)
      assert_equal capture, restarted.fetch_capture(capture.capture_id)
      assert_equal receipt, restarted.fetch_receipt(receipt.receipt_id)
      assert_equal [ capture ], restarted.captures
      assert_equal [ receipt ], restarted.receipts
    end
  end

  def test_same_identity_with_different_bytes_is_corruption
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      store.append_capture(capture)

      conflicting = Hive::Modules::Migration::PatrolCapture.from_h(
        capture.to_h.merge("recorded_at" => (NOW + 60).iso8601(6))
      )
      error = assert_raises(Hive::ConfigError) do
        store.append_capture(conflicting)
      end
      assert_equal "patrol evidence identity conflicts with existing bytes", error.message
    end
  end

  def test_malformed_evidence_fails_closed_after_restart
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      store.append_capture(capture)
      path = File.join(root, "captures", "#{capture.capture_id}.json")
      File.write(path, "{bad")

      restarted = Hive::Modules::Migration::EvidenceStore.new(root: root)
      error = assert_raises(Hive::ConfigError) { restarted.captures }
      assert_equal "patrol evidence is malformed", error.message
    end
  end

  private

  def capture_for(recorded_at:)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "schedule", "id" => "timer-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 2,
      decision_class: "due",
      decision: { "rationale" => "due" },
      occurred_at: NOW,
      recorded_at: recorded_at
    )
  end

  def intent_for
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: "occ-#{'a' * 64}",
      authority: "legacy",
      owner_epoch: 2,
      sink: "pull_request",
      target: "github.com/owner/demo:head-ref",
      idempotency_key: "finding-1:pull-request",
      capability: "github_pull_requests",
      created_at: NOW
    )
  end
end
