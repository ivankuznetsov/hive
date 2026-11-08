require "test_helper"
require "hive/web/status_payload"

class WebStatusPayloadTest < Minitest::Test
  def test_retry_target_matches_the_latest_review_leg_not_an_older_failure
    failed = { "role" => "adversarial", "outcome" => "timeout", "attempt_id" => "failed-review" }
    planner = { "role" => "planner", "outcome" => "success", "attempt_id" => "planner" }
    row = { "plan_review" => { "state" => "retry_scheduled", "routes" => [ failed, planner ] } }
    assert_equal "failed-review", Hive::Web::StatusPayload.task(row).dig("plan_review", "retry_attempt_id")

    row["plan_review"]["routes"] << failed.merge("outcome" => "success", "attempt_id" => "newer-review")
    refute Hive::Web::StatusPayload.task(row).fetch("plan_review").key?("retry_attempt_id")
    row["plan_review"]["routes"] = [ planner ]
    refute Hive::Web::StatusPayload.task(row).fetch("plan_review").key?("retry_attempt_id")
  end

  def test_retry_target_includes_plan_revision_and_triage_attempts
    routes = [ { "role" => "primary", "outcome" => "timeout", "attempt_id" => "older" } ]
    row = { "plan_review" => { "state" => "retry_scheduled", "routes" => routes } }
    %w[planner_revision decision_triage].each do |role|
      routes << { "role" => role, "outcome" => "retryable_failure", "attempt_id" => role }
      assert_equal role, Hive::Web::StatusPayload.task(row).dig("plan_review", "retry_attempt_id")
    end
    routes << { "role" => "verification", "outcome" => "timeout" }
    assert_equal "decision_triage", Hive::Web::StatusPayload.task(row).dig("plan_review", "retry_attempt_id")
  end

  def test_compact_payloads_keep_their_shape_and_do_not_rebuild_retained_containers
    payload = { "tick" => 0 }
    assert_same payload, Hive::Web::StatusPayload.call(payload)

    payload = { "projects" => [ { "tasks" => [ { "plan_review" => { "state" => "cleared" } } ] } ],
      "project_archives" => { "demo" => { "tasks" => [ {} ] } } }
    assert_same payload, Hive::Web::StatusPayload.call(payload)
  end

  def test_malformed_route_entries_do_not_break_the_web_status_frame
    review = { "state" => "retry_scheduled", "routes" => [ nil, 42, "corrupt" ] }
    payload = { "projects" => [ { "tasks" => [ { "plan_review" => review } ] } ] }

    compact = Hive::Web::StatusPayload.call(payload)

    assert_equal({ "state" => "retry_scheduled" }, compact.dig("projects", 0, "tasks", 0, "plan_review"))
    assert_equal [ nil, 42, "corrupt" ], review["routes"]
  end

  def test_completed_reviews_drop_history_and_stale_retry_targets_without_mutating_native_data
    row = JSON.parse(JSON.generate("plan_review" => {
      "state" => "cleared", "retry_attempt_id" => "stale",
      "observation_digest" => "exact", "routes" => [ { "role" => "primary", "outcome" => "timeout" } ]
    }), freeze: true)
    compact = Hive::Web::StatusPayload.task(row)
    assert_equal({ "state" => "cleared", "observation_digest" => "exact" }, compact.fetch("plan_review"))
    assert_same compact, Hive::Web::StatusPayload.task(compact)
    assert row.fetch("plan_review").key?("routes")
    row = { "plan_review" => nil }
    assert_same row, Hive::Web::StatusPayload.task(row)
  end
end
