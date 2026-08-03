require "test_helper"
require "digest"
require "hive/modules/migration/patrol_evidence_verifier"

class ModulesMigrationPatrolEvidenceVerifierTest < Minitest::Test
  NOW = Time.utc(2026, 8, 3, 12)

  def test_verifies_against_independent_caller_supplied_bindings
    receipt = evidence_receipt
    verified = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
      receipt: receipt.to_h,
      expected_bindings: expected_bindings(receipt)
    )

    assert verified.frozen?
    assert_equal receipt.receipt_id, verified.receipt.receipt_id
    assert_equal receipt.capture.capture_id, verified.capture.capture_id
    assert_equal receipt.effects, verified.effects
    assert_match(/\Abinding-[0-9a-f]{64}\z/, verified.binding_digest)
  end

  def test_rejects_foreign_candidate_and_changed_configuration
    receipt = evidence_receipt
    expected = expected_bindings(receipt)
    foreign = evidence_receipt(candidate_sha: "f" * 40)
    changed = evidence_receipt(configuration_digest: "e" * 64)

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: foreign, expected_bindings: expected
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: changed, expected_bindings: expected
      )
    end
  end

  def test_rejects_forged_time_generation_and_projection_bindings
    receipt = evidence_receipt
    expected = expected_bindings(receipt)

    [
      expected.merge("reviewed_at" => (NOW + 60).iso8601(6)),
      expected.merge("owner_epoch" => 2),
      expected.merge("module_projection_digest" => "0" * 64)
    ].each do |changed|
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
          receipt: receipt, expected_bindings: changed
        )
      end
    end
  end

  def test_expected_bindings_are_exact_and_cannot_be_omitted
    receipt = evidence_receipt
    expected = expected_bindings(receipt)
    assert_raises(ArgumentError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        expected_bindings: expected.reject { |key, _| key == "candidate_sha" }
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        expected_bindings: expected.merge("unexpected" => true)
      )
    end
  end

  def test_verification_binds_fault_steps_and_complete_artifact_identity
    receipt = evidence_receipt
    expected = expected_bindings(receipt)

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: evidence_receipt(fault_steps: [ "different_fault" ]),
        expected_bindings: expected
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: evidence_receipt(artifact_kind: "different_kind"),
        expected_bindings: expected
      )
    end
  end

  def test_expected_bindings_reject_string_coercion_and_invalid_utf8
    fault_receipt = evidence_receipt(fault_steps: [ "1" ])
    artifact_receipt = evidence_receipt(artifact_kind: "1")
    digest_receipt = evidence_receipt
    exploding_id = Class.new(String) do
      def match?(*) = raise TypeError, "unavailable match"
    end.new("receipt-#{'8' * 64}")
    mutations = [
      [ fault_receipt,
        expected_bindings(fault_receipt).merge("fault_steps" => [ 1 ]) ],
      [ artifact_receipt,
        expected_bindings(artifact_receipt).merge(
          "artifacts" => [ { "kind" => 1, "digest" => "8" * 64 } ]
        ) ],
      [ digest_receipt,
        expected_bindings(digest_receipt).merge(
          "artifacts" => [
            { "kind" => "comparison", "digest" => Integer("8" * 64) }
          ]
        ) ],
      [ digest_receipt,
        expected_bindings(digest_receipt).merge("reviewer" => "\xFF".b) ],
      [ digest_receipt,
        expected_bindings(digest_receipt).merge(
          "effect_receipt_ids" => [ exploding_id ]
        ) ]
    ]

    mutations.each do |receipt, expected|
      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
          receipt: receipt, expected_bindings: expected
        )
      end
      assert_equal "patrol evidence expected bindings are malformed",
                   error.message
    end
  end

  def test_verified_receipt_cannot_be_constructed_by_an_ordinary_caller
    receipt = evidence_receipt

    assert_raises(NoMethodError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier::VerifiedReceipt.new(
        receipt: receipt,
        binding_digest: "binding-#{'f' * 64}"
      )
    end
    assert_raises(NoMethodError) do
      Hive::Modules::Migration::PatrolEvidenceVerifier::VerifiedReceipt[
        receipt, "binding-#{'f' * 64}"
      ]
    end
  end

  private

  def expected_bindings(receipt)
    {
      "run_id" => "run-1",
      "candidate_sha" => "1" * 40,
      "catalog_digest" => "2" * 64,
      "source_digest" => "3" * 64,
      "manifest_digest" => "4" * 64,
      "configuration_digest" => "5" * 64,
      "scenario_manifest_digest" => "6" * 64,
      "repository" => {
        "id" => "owner/demo", "sha" => "7" * 40,
        "change_window" => "window-1"
      },
      "receipt_id" => receipt.receipt_id,
      "capture_id" => receipt.capture.capture_id,
      "trigger_id" => "manual-1",
      "owner_epoch" => 1,
      "module_projection_digest" => Digest::SHA256.hexdigest(
        Hive::Modules::Migration::PatrolEvidence.canonical(
          receipt.module_projection.to_h
        )
      ),
      "decision_class" => "positive_finding",
      "effect_receipt_ids" => [],
      "fault_steps" => receipt.fault_steps,
      "artifacts" => receipt.artifacts,
      "reviewer" => "reviewer-1",
      "generated_at" => NOW.iso8601(6),
      "reviewed_at" => (NOW + 1).iso8601(6)
    }
  end

  def evidence_receipt(candidate_sha: "1" * 40,
                       configuration_digest: "5" * 64,
                       fault_steps: [ "restart_after_decision" ],
                       artifact_kind: "comparison")
    projection = Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: "patrol", rationale: "due"
    )
    capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1", "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "manual", "id" => "manual-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy", owner_epoch: 1,
      selection_input: { "kind" => "operation", "operation" => "test" },
      selection: projection, outcome_class: "completed",
      outcome: { "rationale" => "completed", "finding_ids" => [] },
      occurred_at: NOW, recorded_at: NOW
    )
    Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      run_id: "run-1", candidate_sha: candidate_sha,
      catalog_digest: "2" * 64, source_digest: "3" * 64,
      manifest_digest: "4" * 64,
      configuration_digest: configuration_digest,
      scenario_manifest_digest: "6" * 64,
      repository: {
        "id" => "owner/demo", "sha" => "7" * 40,
        "change_window" => "window-1"
      },
      capture: capture, module_projection: projection,
      decision_class: "positive_finding", effects: [],
      fault_steps: fault_steps,
      artifacts: [
        { "kind" => artifact_kind, "digest" => "8" * 64 }
      ],
      reviewer: "reviewer-1", generated_at: NOW, reviewed_at: NOW + 1
    )
  end
end
