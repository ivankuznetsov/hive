require "test_helper"
require "hive/one_shot/readiness"

class OneShotReadinessTest < Minitest::Test
  def test_runnable_work_requests_an_immediate_next_pass
    finished_at = Time.utc(2026, 9, 23, 12, 0, 0, 123_456)
    projection = Hive::OneShot::Readiness.project(
      items: [ item("task:1", "runnable_now", "task is dispatchable") ],
      finished_at: finished_at
    )

    assert_equal [ "task:1" ], projection.dig("pending", "runnable_now").map { |row| row["id"] }
    assert_equal "2026-09-23T12:00:00.123456Z", projection["next_due_at"]
    assert_empty projection["wake_conditions"]
  end

  def test_earliest_timed_wait_wins_and_conditions_are_deduplicated
    finished_at = Time.utc(2026, 9, 23, 12, 0, 0)
    condition = { "kind" => "check_state_changed", "repository" => "acme/app", "pr" => 42 }
    projection = Hive::OneShot::Readiness.project(
      items: [
        item("pr:42:checks", "waiting_external", "checks queued",
             next_check_at: finished_at + 300, condition: condition),
        item("pr:42:review", "waiting_external", "review pending",
             next_check_at: finished_at + 120, condition: condition),
        item("task:approval", "waiting_operator", "approval required",
             condition: { "kind" => "operator_action", "task" => "approval" })
      ],
      finished_at: finished_at
    )

    assert_equal "2026-09-23T12:02:00.000000Z", projection["next_due_at"]
    assert_equal 1, projection["wake_conditions"].size
    assert_equal %w[pr:42:checks pr:42:review],
                 projection.dig("wake_conditions", 0, "affected_pending_ids")
    assert_equal [ "task:approval" ],
                 projection.dig("pending", "waiting_operator").map { |row| row["id"] }
  end

  def test_event_only_and_operator_only_waits_have_no_deadline
    finished_at = Time.utc(2026, 9, 23, 12)
    event_wait = Hive::OneShot::Readiness.project(
      items: [ item("pr:7", "waiting_external", "waiting for PR update",
                    condition: { "kind" => "pr_changed", "repository" => "acme/app", "pr" => 7 }) ],
      finished_at: finished_at
    )
    operator_wait = Hive::OneShot::Readiness.project(
      items: [ item("task:q", "waiting_operator", "answer required",
                    condition: { "kind" => "operator_action", "task" => "q" }) ],
      finished_at: finished_at
    )

    assert_nil event_wait["next_due_at"]
    assert_equal "pr_changed", event_wait.dig("wake_conditions", 0, "kind")
    assert_nil operator_wait["next_due_at"]
    assert_empty operator_wait["wake_conditions"]
  end

  def test_overdue_deadline_is_clamped_to_finished_at
    finished_at = Time.utc(2026, 9, 23, 12)
    projection = Hive::OneShot::Readiness.project(
      items: [ item("capacity", "waiting_external", "global capacity",
                    next_check_at: finished_at - 60,
                    condition: { "kind" => "time_due", "resource" => "global_cap" }) ],
      finished_at: finished_at
    )

    assert_equal "2026-09-23T12:00:00.000000Z", projection["next_due_at"]
  end

  def test_empty_projection_has_no_next_due_at
    projection = Hive::OneShot::Readiness.project(items: [], finished_at: Time.utc(2026, 9, 23, 12))

    assert_equal({ "runnable_now" => [], "waiting_external" => [], "waiting_operator" => [] },
                 projection["pending"])
    assert_nil projection["next_due_at"]
    assert_empty projection["wake_conditions"]
  end

  def test_invalid_bucket_and_duplicate_ids_fail_closed
    assert_raises(ArgumentError) do
      Hive::OneShot::Readiness.project(
        items: [ item("x", "unknown", "bad") ], finished_at: Time.now
      )
    end
    assert_raises(ArgumentError) do
      Hive::OneShot::Readiness.project(
        items: [ item("x", "runnable_now", "one"), item("x", "runnable_now", "two") ],
        finished_at: Time.now
      )
    end
  end

  private

  def item(id, bucket, reason, next_check_at: nil, condition: nil)
    {
      "id" => id, "component" => "dispatch", "bucket" => bucket,
      "reason" => reason, "next_check_at" => next_check_at, "condition" => condition
    }
  end
end
