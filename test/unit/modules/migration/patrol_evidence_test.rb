require "test_helper"
require "json"
require "json_schemer"
require "hive/modules/migration/patrol_evidence"

class ModulesMigrationPatrolEvidenceTest < Minitest::Test
  NOW = Time.utc(2026, 7, 28, 12)

  def test_capture_is_strict_deeply_immutable_and_schema_valid
    trigger = {
      "event_id" => "evt-#{'a' * 64}",
      "kind" => "schedule",
      "repository_sha" => "b" * 40
    }
    decision = { "rationale" => "due", "finding_ids" => [ "finding-1" ] }
    capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 3,
      decision_class: "due",
      decision: decision,
      effect_ids: [ "effect-1" ],
      occurred_at: NOW,
      recorded_at: NOW + 1
    )

    trigger["kind"] = "changed"
    decision["finding_ids"] << "finding-2"

    assert capture.frozen?
    assert capture.trigger.frozen?
    assert capture.decision.fetch("finding_ids").frozen?
    assert_equal "schedule", capture.trigger.fetch("kind")
    assert_equal [ "finding-1" ], capture.decision.fetch("finding_ids")
    assert_match(/\Aocc-[0-9a-f]{64}\z/, capture.occurrence_id)
    assert_match(/\Acap-[0-9a-f]{64}\z/, capture.capture_id)

    schema = schema_for("hive-patrol-capture.v1.json")
    assert_empty schema.validate(capture.to_h).to_a

    malformed = capture.to_h.merge("unexpected" => true)
    error = assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.from_h(malformed)
    end
    assert_equal "patrol capture is malformed", error.message
  end

  def test_effect_intent_and_receipt_bind_exact_identity_and_are_immutable
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "architecture-patrol",
      occurrence_id: "occ-#{'a' * 64}",
      authority: "legacy",
      owner_epoch: 4,
      sink: "pull_request",
      target: "github.com/owner/demo:head-ref",
      idempotency_key: "job-7:fix-1:pull-request",
      capability: "github_pull_requests",
      claim_generation: 9,
      created_at: NOW
    )
    outcome = {
      "remote_identity" => {
        "repository" => "owner/demo",
        "number" => 7
      }
    }
    receipt = Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: "committed",
      outcome: outcome,
      recorded_at: NOW + 1
    )

    outcome["remote_identity"]["number"] = 8

    assert intent.frozen?
    assert receipt.frozen?
    assert receipt.outcome.frozen?
    assert_equal 7, receipt.outcome.dig("remote_identity", "number")
    assert_match(/\Aintent-[0-9a-f]{64}\z/, intent.intent_id)
    assert_match(/\Areceipt-[0-9a-f]{64}\z/, receipt.receipt_id)

    schema = schema_for("hive-patrol-effect-receipt.v1.json")
    assert_empty schema.validate(receipt.to_h).to_a

    changed_identity = intent.to_h.merge("target" => "github.com/owner/other:head-ref")
    error = assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectIntent.from_h(changed_identity)
    end
    assert_equal "patrol effect intent identity does not match its contents", error.message
  end

  def test_values_reject_non_json_trees_and_unsupported_vocabulary
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.build(
        module_name: "patrol",
        project: { "project_id" => "p", "name" => "demo", "repository" => nil },
        trigger: { "object" => Object.new },
        reservation: { "kind" => "ordinary", "id" => "r" },
        owner: "legacy",
        owner_epoch: 1,
        decision_class: "due",
        decision: {},
        occurred_at: NOW,
        recorded_at: NOW
      )
    end

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectIntent.build(
        module_name: "patrol",
        occurrence_id: "occ-#{'a' * 64}",
        authority: "shadow",
        owner_epoch: 1,
        sink: "unknown",
        target: "target",
        idempotency_key: "key",
        capability: "none",
        created_at: NOW
      )
    end
  end

  private

  def schema_for(name)
    path = File.join(Hive::Schemas.schema_dir, name)
    assert File.file?(path), "schema file missing: #{path}"
    JSONSchemer.schema(JSON.parse(File.read(path)))
  end
end
