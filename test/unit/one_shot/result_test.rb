require "test_helper"
require "hive/one_shot/result"

class OneShotResultTest < Minitest::Test
  STARTED = Time.utc(2026, 9, 23, 11, 59, 59)
  FINISHED = Time.utc(2026, 9, 23, 12, 0, 0)

  def test_ok_report_retains_completed_work_and_readiness
    result = Hive::OneShot::Result.ok(
      component: "dispatch", project: "app", started_at: STARTED, finished_at: FINISHED,
      ran: [ { "id" => "task:1", "action" => "advance", "outcome" => "completed" } ],
      items: [ item("task:2", "runnable_now") ], safe_to_stop: true
    )

    assert_equal "hive-one-shot", result.to_h["schema"]
    assert_equal "ok", result.to_h["status"]
    assert_equal "2026-09-23T12:00:00.000000Z", result.to_h["next_due_at"]
    assert result.safe_to_stop?
    assert_equal Hive::ExitCodes::SUCCESS, result.exit_code
  end

  def test_refusal_and_error_withhold_readiness
    owner = { "kind" => "daemon", "pid" => 123, "process_identity" => "boot:123" }
    refused = Hive::OneShot::Result.refused(
      component: "patrol", project: "app", started_at: STARTED, finished_at: FINISHED,
      code: "daemon_owned", message: "daemon owns project", owner: owner
    )
    failed = Hive::OneShot::Result.error(
      component: "dispatch", project: "app", started_at: STARTED, finished_at: FINISHED,
      code: "drain_failed", message: "worker did not settle",
      ran: [ { "id" => "task:1", "action" => "advance", "outcome" => "started" } ]
    )

    [ refused, failed ].each do |result|
      assert_nil result.to_h["pending"]
      assert_nil result.to_h["next_due_at"]
      refute result.to_h["safe_to_stop"]
      assert_equal Hive::ExitCodes::TEMPFAIL, result.exit_code
    end
    assert_equal owner, refused.to_h["owner"]
    assert_equal 1, failed.to_h["ran"].size
  end

  def test_aggregate_combines_successful_projects_and_vetoes_host_stop_for_owner
    success = Hive::OneShot::Result.ok(
      component: "babysitter", project: "app", started_at: STARTED, finished_at: FINISHED,
      ran: [], items: [ item("pr:1", "waiting_external", FINISHED + 120) ], safe_to_stop: true
    )
    owner = { "kind" => "daemon", "pid" => 123, "process_identity" => "boot:123" }
    refused = Hive::OneShot::Result.refused(
      component: "babysitter", project: "api", started_at: STARTED, finished_at: FINISHED,
      code: "daemon_owned", message: "owned", owner: owner
    )
    aggregate = Hive::OneShot::Result.aggregate(
      component: "babysitter", reports: [ success, refused ],
      started_at: STARTED, finished_at: FINISHED
    )

    assert_equal "ok", aggregate.to_h["status"]
    assert_equal Hive::ExitCodes::SUCCESS, aggregate.exit_code
    assert_equal [ "app:pr:1" ],
                 aggregate.to_h.dig("pending", "waiting_external").map { |row| row["id"] }
    refute aggregate.to_h["safe_to_stop"]
    refute aggregate.to_h["host_stop_allowed"]
    assert_equal [ { "project" => "api", "owner" => owner } ], aggregate.to_h["owning_projects"]
  end

  def test_all_refused_and_zero_project_aggregates_succeed_without_claiming_host_idle
    refused = Hive::OneShot::Result.refused(
      component: "babysitter", project: "api", started_at: STARTED, finished_at: FINISHED,
      code: "one_shot_busy", message: "owned",
      owner: { "kind" => "one_shot", "pid" => 456, "process_identity" => "boot:456" }
    )
    all_refused = Hive::OneShot::Result.aggregate(
      component: "babysitter", reports: [ refused ], started_at: STARTED, finished_at: FINISHED
    )
    empty = Hive::OneShot::Result.aggregate(
      component: "babysitter", reports: [], started_at: STARTED, finished_at: FINISHED
    )

    assert_equal "ok", all_refused.to_h["status"]
    refute all_refused.to_h["host_stop_allowed"]
    assert empty.to_h["safe_to_stop"]
    assert empty.to_h["host_stop_allowed"]
    assert_empty empty.to_h["projects"]
  end

  def test_aggregate_observation_error_or_unknown_result_is_partial_failure
    failed = Hive::OneShot::Result.error(
      component: "babysitter", project: "api", started_at: STARTED, finished_at: FINISHED,
      code: "observation_failed", message: "GitHub unavailable"
    )
    [ [ failed ], [ Object.new ] ].each do |reports|
      aggregate = Hive::OneShot::Result.aggregate(
        component: "babysitter", reports: reports, started_at: STARTED, finished_at: FINISHED
      )

      assert_equal "error", aggregate.to_h["status"]
      assert_equal "partial_failure", aggregate.to_h.dig("error", "code")
      assert_nil aggregate.to_h["pending"]
      refute aggregate.to_h["host_stop_allowed"]
      assert_equal Hive::ExitCodes::TEMPFAIL, aggregate.exit_code
    end
  end

  def test_unverifiable_refusal_is_partial_failure
    report = Hive::OneShot::Result.refused(
      component: "patrol", project: "app", started_at: STARTED, finished_at: FINISHED,
      code: "ownership_unverifiable", message: "cannot verify owner", owner: nil
    )
    aggregate = Hive::OneShot::Result.aggregate(
      component: "patrol", reports: [ report ], started_at: STARTED, finished_at: FINISHED
    )

    assert_equal "error", aggregate.to_h["status"]
    assert_empty aggregate.to_h["owning_projects"]
  end

  private

  def item(id, bucket, next_check_at = nil)
    {
      "id" => id, "component" => "babysitter", "bucket" => bucket,
      "reason" => "waiting", "next_check_at" => next_check_at,
      "condition" => bucket == "waiting_external" ?
        { "kind" => "check_state_changed", "repository" => "acme/app", "pr" => 1 } : nil
    }
  end
end
