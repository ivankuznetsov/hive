require "test_helper"
require "hive/workflow_package/publish_receipt"

class WorkflowPackagePublishReceiptTest < Minitest::Test
  Receipt = Hive::WorkflowPackage::PublishReceipt

  def test_identity_is_immutable_and_progress_is_monotonic
    receipt = Receipt.build(**identity)
    receipt = receipt.advance("prepared", direct_submission_fields)
    receipt = receipt.advance("push_intent", "commit_oid" => "c" * 40)

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
    receipt = submitted_receipt.observe(
      state: "pending_review", observed_at: "2026-07-21T12:00:00Z",
      pr_url: "https://github.com/owner/registry/pull/1", pr_number: 1
    )

    assert_equal "pending_review", receipt.observation.fetch("state")
    assert_equal "2026-07-21T12:00:00Z", receipt.observation.fetch("observed_at")
    cached = receipt.cached_observation
    assert_equal "cached", cached.fetch("freshness")
    assert_equal receipt.observation.fetch("observed_at"), cached.fetch("observed_at")
  end

  def test_continuations_cannot_erase_write_once_fields_or_regress_observations
    submitted = submitted_receipt
    pending = submitted.observe(
      state: "pending_review", observed_at: "2026-07-21T12:00:00Z",
      pr_url: "https://github.com/owner/registry/pull/1", pr_number: 1
    )
    listed = pending.observe(
      state: "listed", observed_at: "2026-07-21T13:00:00Z",
      pr_url: "https://github.com/owner/registry/pull/1", pr_number: 1
    )

    assert_same listed, pending.assert_continuation!(listed)
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      listed.assert_continuation!(pending)
    end
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      listed.assert_continuation!(submitted)
    end
  end

  def test_receipt_parser_rejects_unknown_versions_and_malformed_mode_fields
    data = Receipt.build(**identity).data
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      Receipt.from_h(data.merge("schema" => "future"))
    end
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      Receipt.from_h(data.merge("submission_mode" => "direct", "head_repository" => "other/fork"))
    end
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      Receipt.from_h(data.merge("lint_contract" => data.fetch("lint_contract").slice(
        "version", "upstream_commit", "contract_sha256"
      )))
    end
  end

  def test_continuation_rejects_invalid_backwards_and_changed_authority
    validated = Receipt.build(**identity)
    prepared = validated.advance("prepared", direct_submission_fields)
    pushed = prepared.advance("push_intent", "commit_oid" => "c" * 40)

    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      pushed.assert_continuation!(Object.new)
    end
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      pushed.assert_continuation!(prepared)
    end

    changed = validated.advance(
      "prepared", direct_submission_fields.merge("owner" => "different")
    )
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      prepared.assert_continuation!(changed)
    end

    current = submitted_receipt.observe(
      state: "pending_review", observed_at: "2026-07-21T13:00:00Z",
      pr_url: "https://github.com/owner/registry/pull/1", pr_number: 1
    )
    older = submitted_receipt.observe(
      state: "pending_review", observed_at: "2026-07-21T12:00:00Z",
      pr_url: "https://github.com/owner/registry/pull/1", pr_number: 1
    )
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      current.assert_continuation!(older)
    end
  end

  def test_step_and_observation_shape_invariants_fail_closed
    prepared = Receipt.build(**identity).advance("prepared", direct_submission_fields)
    cases = [
      prepared.data.merge("last_completed_step" => "fork_create_intent"),
      prepared.data.merge(
        "pr_number" => 1, "pr_url" => "https://github.com/owner/registry/pull/1"
      ),
      prepared.data.merge(
        "observation" => {
          "state" => "pending_review", "freshness" => "current",
          "observed_at" => "2026-07-21T12:00:00Z"
        }
      )
    ]
    cases.each do |data|
      assert_raises(Hive::WorkflowPackage::PublishRecoveryError) { Receipt.from_h(data) }
    end

    base = submitted_receipt.data
    malformed_observations = [
      { "state" => "unknown", "freshness" => "current", "observed_at" => "2026-07-21T12:00:00Z" },
      {
        "state" => "pending_review", "freshness" => "current",
        "observed_at" => "2026-07-21T12:00:00Z", "pr_number" => 0
      },
      { "state" => "pending_review", "freshness" => "current", "observed_at" => "not-time" }
    ]
    malformed_observations.each do |observation|
      assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
        Receipt.from_h(base.merge("observation" => observation))
      end
    end
  end

  def test_receipt_copy_and_freeze_helpers_recurse_through_arrays
    receipt = Receipt.build(**identity)
    copied = receipt.send(:deep_copy, [ { symbol: [ "value" ] } ])
    assert_equal [ { "symbol" => [ "value" ] } ], copied

    frozen = receipt.send(:deep_freeze, copied)
    assert_predicate frozen, :frozen?
    assert_predicate frozen.first.fetch("symbol"), :frozen?
  end

  private

  def submitted_receipt
    Receipt.build(**identity).advance(
      "pr_verified",
      direct_submission_fields.merge(
        "commit_oid" => "c" * 40, "pr_number" => 1,
        "pr_url" => "https://github.com/owner/registry/pull/1"
      )
    )
  end

  def direct_submission_fields
    {
      "submission_mode" => "direct", "destination_repository" => "owner/registry",
      "base_branch" => "main", "base_sha" => "b" * 40,
      "head_repository" => "owner/registry", "head_branch" => "honeycomb-demo",
      "owner" => "owner"
    }
  end

  def identity
    {
      registry: "owner/registry", name: "demo", version: "1.2.3",
      package_digest: "a" * 64, release_digest: "b" * 64,
      lint_contract: {
        "version" => "v1", "upstream_commit" => "c" * 40,
        "upstream_policy_sha256" => "e" * 64,
        "fixture_corpus_sha256" => "f" * 64,
        "expected_output_sha256" => "0" * 64,
        "contract_sha256" => "d" * 64
      }
    }
  end
end
