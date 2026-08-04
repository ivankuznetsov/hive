require_relative "../../test_helper"
require_relative "patrol_public_evidence_collector"

class E2EPatrolPublicEvidenceCollectorTest < Minitest::Test
  def test_prepares_receipt_and_bindings_from_raw_persisted_evidence
    collector = Hive::E2E::PatrolPublicEvidenceCollector.new(common: common)
    prepared = collector.prepare(
      record: record,
      repository: {
        "id" => "github.com/acme/hive-e2e",
        "sha" => "e" * 40,
        "change_window" => "a..e"
      },
      decision_class: "due",
      fault_steps: [ "daemon_child_completed" ],
      generated_at: "2026-08-03T12:00:00.000000Z",
      reviewed_at: "2026-08-03T12:00:01.000000Z"
    )

    assert_match(/\Aevidence-[0-9a-f]{64}\z/, prepared.document.fetch("receipt_id"))
    assert_equal "capture-1", prepared.bindings.fetch("capture_id")
    assert_equal "trigger-1", prepared.bindings.fetch("trigger_id")
    assert_equal [ "effect-1" ], prepared.bindings.fetch("effect_receipt_ids")
    assert_same prepared.document, collector.accept!(prepared, prepared.document)
  end

  def test_rejects_a_receipt_that_differs_from_the_control
    collector = Hive::E2E::PatrolPublicEvidenceCollector.new(common: common)
    prepared = collector.prepare(
      record: record,
      repository: {
        "id" => "github.com/acme/hive-e2e",
        "sha" => "e" * 40,
        "change_window" => "a..e"
      },
      decision_class: "due", fault_steps: [],
      generated_at: "2026-08-03T12:00:00.000000Z",
      reviewed_at: "2026-08-03T12:00:01.000000Z"
    )

    error = assert_raises(RuntimeError) do
      collector.accept!(
        prepared,
        prepared.document.merge("decision_class" => "fabricated")
      )
    end
    assert_match(/independent control/, error.message)
  end

  private

  def common
    {
      "run_id" => "u3b-test",
      "candidate_sha" => "a" * 40,
      "catalog_digest" => "b" * 64,
      "source_digest" => "c" * 64,
      "manifest_digest" => "d" * 64,
      "scenario_manifest_digest" => "e" * 64,
      "artifacts" => [ { "kind" => "catalog", "digest" => "f" * 64 } ],
      "reviewer" => "hive-e2e/u3b"
    }
  end

  def record
    {
      "configuration_digest" => "1" * 64,
      "legacy_capture" => {
        "capture_id" => "capture-1",
        "trigger" => { "id" => "trigger-1" },
        "owner_epoch" => 1
      },
      "module_decision" => { "module" => "patrol", "rationale" => "due" },
      "legacy_effects" => [ { "receipt_id" => "effect-1" } ],
      "module_effects" => []
    }
  end
end
