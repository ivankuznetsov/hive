require "test_helper"
require "json"
require "json_schemer"
require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/patrol_decision_projection"

class ModulesMigrationPatrolEvidenceTest < Minitest::Test
  NOW = Time.utc(2026, 7, 28, 12)

  def test_capture_separates_strict_selection_from_terminal_outcome
    input = {
      "kind" => "schedule",
      "enabled" => true,
      "trigger" => "timer",
      "timer_due" => true,
      "branch_changed" => nil
    }
    selection = Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: "patrol",
      rationale: "due"
    )
    provisional = Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: {
        "kind" => "schedule",
        "id" => "tick-1",
        "schedule" => "continuous",
        "occurred_at" => NOW.iso8601(6)
      },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 3,
      selection_input: input,
      selection: selection,
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    )
    final = Hive::Modules::Migration::PatrolCapture.build(
      module_name: provisional.module_name,
      project: provisional.project,
      trigger: provisional.trigger,
      reservation: provisional.reservation,
      owner: provisional.owner,
      owner_epoch: provisional.owner_epoch,
      selection_input: provisional.selection_input,
      selection: provisional.selection,
      outcome_class: "completed",
      outcome: { "rationale" => "completed", "ok" => true },
      occurred_at: provisional.occurred_at,
      recorded_at: NOW + 1
    )

    assert_equal provisional.occurrence_id, final.occurrence_id
    assert_equal provisional.selection_input, final.selection_input
    assert_equal provisional.selection, final.selection
    assert_nil provisional.outcome
    assert_equal true, final.outcome.fetch("ok")
    assert_empty schema_for("hive-patrol-capture.v1.json").validate(final.to_h).to_a

    old_shape = final.to_h.merge(
      "decision_class" => "completed",
      "decision" => { "rationale" => "completed" }
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.from_h(old_shape)
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolDecisionProjection.from_h(
        selection.to_h.merge("extra" => true)
      )
    end
    bypassed = Hive::Modules::Migration::PatrolDecisionProjection.new(
      module_name: "patrol",
      rationale: "invalid",
      job_id: nil,
      phase: nil
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.build(
        module_name: provisional.module_name,
        project: provisional.project,
        trigger: provisional.trigger,
        reservation: provisional.reservation,
        owner: provisional.owner,
        owner_epoch: provisional.owner_epoch,
        selection_input: provisional.selection_input,
        selection: bypassed,
        outcome_class: nil,
        outcome: nil,
        occurred_at: provisional.occurred_at,
        recorded_at: provisional.recorded_at
      )
    end
  end

  def test_capture_is_strict_deeply_immutable_and_schema_valid
    trigger = {
      "kind" => "schedule",
      "id" => "tick-1",
      "schedule" => "continuous",
      "occurred_at" => NOW.iso8601(6)
    }
    outcome = { "rationale" => "completed", "finding_ids" => [ "finding-1" ] }
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
      selection_input: ordinary_input,
      selection: ordinary_selection,
      outcome_class: "completed",
      outcome: outcome,
      effect_ids: [ "effect-1" ],
      occurred_at: NOW,
      recorded_at: NOW + 1
    )

    trigger["kind"] = "changed"
    outcome["finding_ids"] << "finding-2"

    assert capture.frozen?
    assert capture.trigger.frozen?
    assert capture.outcome.fetch("finding_ids").frozen?
    assert_equal "schedule", capture.trigger.fetch("kind")
    assert_equal [ "finding-1" ], capture.outcome.fetch("finding_ids")
    assert_match(/\Aocc-[0-9a-f]{64}\z/, capture.occurrence_id)
    assert_match(/\Acap-[0-9a-f]{64}\z/, capture.capture_id)

    schema = schema_for("hive-patrol-capture.v1.json")
    assert_empty schema.validate(capture.to_h).to_a

    malformed = capture.to_h.merge("unexpected" => true)
    error = assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.from_h(malformed)
    end
    assert_equal "patrol capture is malformed", error.message
    %w[trigger reservation].each do |field|
      nested = capture.to_h.merge(
        field => capture.to_h.fetch(field).merge("unexpected" => true)
      )
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolCapture.from_h(nested)
      end
      refute schema.valid?(nested)
    end
  end

  def test_capture_and_projection_schemas_reject_runtime_invalid_combinations
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
      selection_input: ordinary_input,
      selection: ordinary_selection,
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    ).to_h
    architecture_input = {
      "kind" => "candidate",
      "job_id" => "job-1",
      "phase" => "discovery"
    }
    architecture_projection = {
      "module" => "architecture-patrol",
      "rationale" => "due",
      "job_id" => "job-1",
      "phase" => "discovery"
    }
    capture_schema = schema_for("hive-patrol-capture.v1.json")
    projection_schema = schema_for(
      "hive-patrol-decision-projection.v1.json"
    )

    assert capture_schema.valid?(capture)
    assert projection_schema.valid?(capture.fetch("selection"))
    malformed = [
      capture.merge("selection_input" => architecture_input),
      capture.merge("selection" => architecture_projection),
      capture.merge(
        "selection" => capture.fetch("selection").reject {
          |key, _value| key == "phase"
        }
      ),
      capture.merge(
        "selection" => capture.fetch("selection").merge("extra" => true)
      ),
      capture.merge(
        "outcome_class" => "complete",
        "outcome" => nil
      ),
      capture.merge(
        "outcome_class" => nil,
        "outcome" => { "ok" => true }
      ),
      capture.merge(
        "effect_ids" => Array.new(129) { |index| "effect-#{index}" }
      )
    ]
    malformed.each do |value|
      refute capture_schema.valid?(value), value.inspect
    end
    refute projection_schema.valid?(
      capture.fetch("selection").reject { |key, _value| key == "job_id" }
    )
    refute projection_schema.valid?(
      capture.fetch("selection").merge("extra" => true)
    )
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
    outcome = { "pr_url" => "https://github.com/owner/demo/pull/7" }
    receipt = Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: "committed",
      outcome: outcome,
      recorded_at: NOW + 1
    )

    outcome["pr_url"] = "https://github.com/owner/demo/pull/8"

    assert intent.frozen?
    assert receipt.frozen?
    assert receipt.outcome.frozen?
    assert_equal(
      "https://github.com/owner/demo/pull/7",
      receipt.outcome.fetch("pr_url")
    )
    assert_match(/\Aintent-[0-9a-f]{64}\z/, intent.intent_id)
    assert_match(/\Aauth-[0-9a-f]{64}\z/, intent.authorization_digest)
    assert_match(/\Areceipt-[0-9a-f]{64}\z/, receipt.receipt_id)

    schema = schema_for("hive-patrol-effect-receipt.v1.json")
    assert_empty schema.validate(receipt.to_h).to_a

    unknown_scope = intent.to_h.merge(
      "scope" => intent.scope.merge("unexpected" => true)
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectIntent.from_h(unknown_scope)
    end
    refute schema.valid?(
      receipt.to_h.merge("intent" => unknown_scope)
    )
    unknown_outcome = receipt.to_h.merge(
      "outcome" => receipt.outcome.merge("unexpected" => true)
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectReceipt.from_h(unknown_outcome)
    end
    refute schema.valid?(unknown_outcome)

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
        selection_input: ordinary_input,
        selection: ordinary_selection,
        outcome_class: nil,
        outcome: nil,
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
        selection_input: ordinary_input,
        selection: ordinary_selection,
        outcome_class: nil,
        outcome: nil,
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
      selection_input: ordinary_input,
      selection: ordinary_selection,
      outcome_class: nil,
      outcome: nil,
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

  def test_architecture_operation_selection_is_strict_and_round_trips
    selection = Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: "architecture-patrol",
      rationale: "due",
      job_id: "job-1",
      phase: "action"
    )
    capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: { "project_id" => "project-1", "name" => "demo", "repository" => nil },
      trigger: { "kind" => "manual", "id" => "architecture-operation" },
      reservation: { "kind" => "architecture", "id" => "job-1", "job_id" => "job-1" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "job_id" => "job-1",
        "operation" => "resume",
        "phase" => "action"
      },
      selection: selection,
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    )

    assert_equal capture.to_h,
                 Hive::Modules::Migration::PatrolCapture.from_h(capture.to_h).to_h
    invalid = capture.to_h
                    .merge("selection_input" => { "kind" => "unexpected" })
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolCapture.from_h(invalid)
    end
  end

  private

  def ordinary_input
    {
      "kind" => "operation",
      "operation" => "test"
    }
  end

  def ordinary_selection
    Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: "patrol",
      rationale: "due"
    )
  end

  def schema_for(name)
    path = File.join(Hive::Schemas.schema_dir, name)
    assert File.file?(path), "schema file missing: #{path}"
    JSONSchemer.schema(JSON.parse(File.read(path)))
  end
end
