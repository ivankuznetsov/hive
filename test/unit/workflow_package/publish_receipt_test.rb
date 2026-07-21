require "test_helper"
require "hive/workflow_package/publish_receipt"

class WorkflowPackagePublishReceiptTest < Minitest::Test
  Receipt = Hive::WorkflowPackage::PublishReceipt

  def test_identity_is_immutable_and_progress_is_monotonic
    receipt = Receipt.build(**identity)
    receipt = receipt.advance("prepared", "base_sha" => "b" * 40)
    receipt = receipt.advance(
      "push_intent", "submission_mode" => "direct",
      "destination_repository" => "owner/registry", "base_branch" => "main",
      "head_repository" => "owner/registry", "head_branch" => "honeycomb-demo",
      "owner" => "owner", "commit_oid" => "c" * 40
    )

    assert_equal "push_intent", receipt.last_completed_step
    assert_equal "c" * 40, receipt.data.fetch("commit_oid")
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) { receipt.advance("prepared") }
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      receipt.advance("push_intent", "commit_oid" => "d" * 40)
    end
    assert_raises(Hive::WorkflowPackage::PublishConflict) do
      receipt.assert_identity!(**identity.merge(release_digest: "e" * 64))
    end
  end

  def test_current_observation_is_separate_from_identity_and_preserves_timestamp
    receipt = Receipt.build(**identity).observe(
      state: "pending_review", observed_at: "2026-07-21T12:00:00Z",
      pr_url: "https://github.com/owner/registry/pull/1", pr_number: 1
    )

    assert_equal "pending_review", receipt.observation.fetch("state")
    assert_equal "2026-07-21T12:00:00Z", receipt.observation.fetch("observed_at")
    cached = receipt.cached_observation
    assert_equal "cached", cached.fetch("freshness")
    assert_equal receipt.observation.fetch("observed_at"), cached.fetch("observed_at")
  end

  def test_receipt_parser_rejects_unknown_versions_and_malformed_mode_fields
    data = Receipt.build(**identity).data
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      Receipt.from_h(data.merge("schema" => "future"))
    end
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      Receipt.from_h(data.merge("submission_mode" => "direct", "head_repository" => "other/fork"))
    end
  end

  private

  def identity
    {
      registry: "owner/registry", name: "demo", version: "1.2.3",
      package_digest: "a" * 64, release_digest: "b" * 64,
      lint_contract: {
        "version" => "v1", "upstream_commit" => "c" * 40,
        "contract_sha256" => "d" * 64
      }
    }
  end
end
