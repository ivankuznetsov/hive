require "test_helper"
require "hive/finalization/projection"

class FinalizationProjectionTest < Minitest::Test
  def test_deep_copy_recursively_copies_arrays
    original = [ { "values" => [ "one" ] } ]

    copied = Hive::Finalization::Projection.deep_copy(original)
    copied.first.fetch("values") << "two"

    assert_equal [ "one" ], original.first.fetch("values")
  end

  NOW = Time.utc(2026, 7, 17, 13, 0, 0)

  def test_normal_lifecycle_folds_to_archive_ready
    records = [
      event(:finalized),
      event(:babysitter_active, event_id: "active", producer: babysitter),
      event(:merge_ready, event_id: "ready", producer: babysitter),
      event(:merged, event_id: "merged", producer: babysitter,
            payload: coordinates.merge("merged_at" => NOW.iso8601)),
      event(:archive_ready, event_id: "archive", producer: reconciler,
            payload: coordinates.merge("terminal_event_id" => "merged"))
    ]

    projection = Hive::Finalization::Projection.project(records: records)

    assert_equal "archive_ready", projection.fetch("state")
    assert_equal "job-1", projection.fetch("job_id")
    assert_equal 1, projection.fetch("head_generation")
    assert_equal "merged", projection.dig("evidence", "terminal_event_id")
    assert_equal "archive", projection.dig("evidence", "archive_ready_event_id")
    assert_equal "archive", projection.dig("safe_action", "code")
  end

  def test_attempt_adoption_preserves_readiness_but_head_change_invalidates_it
    records = [
      event(:finalized),
      event(:merge_ready, event_id: "ready", producer: babysitter),
      event(:finalize_attempt_adopted, event_id: "adopt", attempt_id: "attempt-2",
            producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-2" },
            payload: coordinates.merge("finalize_attempt_id" => "attempt-2"))
    ]
    adopted = Hive::Finalization::Projection.project(records: records)
    assert_equal "merge_ready", adopted.fetch("state")
    assert_equal "attempt-2", adopted.fetch("finalize_attempt_id")

    records << event(
      :head_superseded,
      event_id: "head-2",
      producer: babysitter,
      payload: coordinates.merge(
        "head_sha" => "b" * 40,
        "head_generation" => 2,
        "finalize_attempt_id" => "attempt-2"
      )
    )
    superseded = Hive::Finalization::Projection.project(records: records)
    assert_equal "babysitter_active", superseded.fetch("state")
    assert_equal 2, superseded.fetch("head_generation")
    assert_nil superseded.dig("evidence", "merge_ready_event_id")
  end

  def test_closed_unmerged_is_blocked_and_never_terminal
    records = [
      event(:finalized),
      event(
        :babysitter_blocked,
        event_id: "closed",
        producer: babysitter,
        payload: coordinates.merge(
          "blocker" => {
            "code" => "closed_unmerged",
            "needs_human" => true,
            "detail" => "Pull request closed without merge",
            "source" => "github"
          }
        )
      )
    ]
    projection = Hive::Finalization::Projection.project(records: records)

    assert_equal "blocked", projection.fetch("state")
    assert_equal "closed_unmerged", projection.dig("blocker", "code")
    assert_equal "confirm_terminal_outcome", projection.dig("safe_action", "code")
    assert_nil projection.dig("evidence", "terminal_event_id")
  end

  private

  def event(type, event_id: type.to_s, attempt_id: "attempt-1", producer: nil, payload: nil)
    producer ||= { "kind" => "finalize_attempt", "attempt_id" => attempt_id }
    Hive::TaskJournal::Envelope.authoritative({
      event_type: type.to_s,
      event_id: event_id,
      occurred_at: NOW.iso8601(6),
      observed_at: NOW.iso8601(6),
      task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding",
      stage: "8-finalize",
      attempt_id: attempt_id,
      task_generation: 3,
      ownership_generation: "ownership-1",
      reason: type.to_s,
      evidence: [],
      provenance: { "source" => "test" },
      producer: producer,
      payload: payload || coordinates
    })
  end

  def coordinates
    {
      "job_id" => "job-1",
      "repository" => "github.com/acme/demo",
      "pr_number" => 12,
      "pr_url" => "https://github.com/acme/demo/pull/12",
      "head_sha" => "a" * 40,
      "head_generation" => 1,
      "finalize_attempt_id" => "attempt-1"
    }
  end

  def babysitter
    { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 4 }
  end

  def reconciler
    { "kind" => "reconciler", "name" => "hive-finalization-reconciler-v1" }
  end
end
