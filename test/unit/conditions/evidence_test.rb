require "test_helper"
require "hive/conditions/evidence"

class ConditionsEvidenceTest < Minitest::Test
  def test_each_evidence_variant_validates_and_round_trips
    variants = [
      { type: "journal_event", event_id: "event-1", detail: "explicit-negative" },
      { type: "attempt_lease", attempt_id: "attempt-1", lease_version: 2, state: "running" },
      { type: "commit", sha: "a" * 40, branch: "feature" },
      { type: "file", path: "artifact.md", digest: "b" * 64 },
      { type: "pull_request", url: "https://example.test/pull/1", number: 1,
        observed_head_sha: "c" * 40, state: "OPEN" },
      { type: "task_closure", receipt_digest: "d" * 64, evidence_digest: "e" * 64,
        reason: "already_delivered", authority: "remote_merge" }
    ]

    variants.each do |variant|
      result = Hive::Conditions::Evidence.validate!(variant)
      assert_equal variant.transform_keys(&:to_s), result
      assert result.frozen?
    end
  end

  def test_invalid_or_disallowed_evidence_fails_closed
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!({ type: "unknown" })
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!({ type: "commit", sha: "short", branch: "main" })
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!(
        { type: "journal_event", event_id: "event" }, allowed: [ :commit ]
      )
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!({ type: "file", path: "x", digest: "nope" })
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!(
        { type: "attempt_lease", attempt_id: "attempt", lease_version: -1, state: "running" }
      )
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!(
        { type: "pull_request", url: "https://example.test/pull/1", number: 0,
          observed_head_sha: "a" * 40, state: "OPEN" }
      )
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!(
        { type: "task_closure", receipt_digest: "short", evidence_digest: "e" * 64,
          reason: "already_delivered", authority: "remote_merge" }
      )
    end
    assert_raises(Hive::Conditions::InvalidEvidence) do
      Hive::Conditions::Evidence.validate!(
        { type: "task_closure", receipt_digest: "d" * 64, evidence_digest: "e" * 64,
          reason: "equal_refs", authority: "remote_merge" }
      )
    end
  end

  def test_nested_evidence_is_stringified_and_deeply_frozen
    result = Hive::Conditions::Evidence.validate!({
      type: "journal_event", event_id: "event-1", detail: [ { source: "reconciler" } ]
    })

    assert_equal "reconciler", result.dig("detail", 0, "source")
    assert result.fetch("detail").frozen?
    assert result.dig("detail", 0).frozen?
  end
end
