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
      scope: {
        "job_id" => "job-7",
        "canonical_action_id" => "action-1"
      },
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
    assert_match(/\Aauth-[0-9a-f]{64}\z/, intent.authorization_digest)
    assert_match(/\Areceipt-[0-9a-f]{64}\z/, receipt.receipt_id)

    schema = schema_for("hive-patrol-effect-receipt.v1.json")
    assert_empty schema.validate(receipt.to_h).to_a

    changed_identity = intent.to_h.merge("target" => "github.com/owner/other:head-ref")
    error = assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectIntent.from_h(changed_identity)
    end
    assert_equal "patrol effect intent identity does not match its contents", error.message

    changed_authority = intent.to_h.merge("claim_generation" => 10)
    error = assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectIntent.from_h(changed_authority)
    end
    assert_equal(
      "patrol effect intent authorization does not match its contents",
      error.message
    )
  end

  def test_claim_generation_is_a_fence_not_semantic_effect_identity
    attributes = {
      module_name: "architecture-patrol",
      occurrence_id: "occ-#{'a' * 64}",
      authority: "legacy",
      owner_epoch: 4,
      sink: "issue",
      target: "github.com/owner/demo:family-1",
      idempotency_key: "job-7:action-1:issue",
      capability: "github_issues",
      scope: {
        "job_id" => "job-7",
        "canonical_action_id" => "action-1"
      },
      created_at: NOW
    }
    first = Hive::Modules::Migration::EffectIntent.build(
      **attributes, claim_generation: 9
    )
    retried = Hive::Modules::Migration::EffectIntent.build(
      **attributes, claim_generation: 10, created_at: NOW + 60
    )

    assert_equal first.intent_id, retried.intent_id
    refute_equal first.authorization_digest, retried.authorization_digest
  end

  def test_structural_limits_reject_deep_or_oversized_evidence
    deep = {}
    cursor = deep
    (Hive::Modules::Migration::PatrolEvidence::MAX_JSON_DEPTH + 1).times do
      cursor["child"] = {}
      cursor = cursor.fetch("child")
    end

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.build(
        module_name: "patrol",
        project: { "project_id" => "p", "name" => "demo", "repository" => nil },
        trigger: deep,
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
      Hive::Modules::Migration::EffectReceipt.build(
        intent: Hive::Modules::Migration::EffectIntent.build(
          module_name: "patrol",
          occurrence_id: "occ-#{'a' * 64}",
          authority: "legacy",
          owner_epoch: 1,
          sink: "state",
          target: "state",
          idempotency_key: "state",
          capability: "filesystem_write",
          created_at: NOW
        ),
        status: "committed",
        outcome: {
          "payload" => "x" * Hive::Modules::Migration::PatrolEvidence::MAX_RECEIPT_BYTES
        },
        recorded_at: NOW
      )
    end
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

  def test_scalar_validation_and_forged_evidence_fail_closed
    evidence = Hive::Modules::Migration::PatrolEvidence
    assert_equal 1.25, evidence.immutable_json(1.25, label: "number")
    assert_raises(Hive::ConfigError) do
      evidence.immutable_json(Float::NAN, label: "number")
    end
    assert_raises(Hive::ConfigError) do
      evidence.timestamp("not-a-time", label: "timestamp")
    end
    assert_raises(Hive::ConfigError) do
      evidence.positive_integer("many", label: "count")
    end
    assert_raises(Hive::ConfigError) do
      evidence.optional_generation("later", label: "generation")
    end

    capture = Hive::Modules::Migration::PatrolCapture.build(
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
      decision: {},
      occurred_at: NOW,
      recorded_at: NOW
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.from_h(
        capture.to_h.merge("capture_id" => "cap-#{'0' * 64}")
      )
    end

    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "state",
      target: "state",
      idempotency_key: "state",
      capability: "filesystem_write",
      created_at: NOW
    )
    receipt = Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: "committed",
      outcome: {},
      recorded_at: NOW
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectReceipt.from_h(
        receipt.to_h.merge("receipt_id" => "receipt-#{'0' * 64}")
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
