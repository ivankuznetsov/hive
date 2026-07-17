require "test_helper"
require "hive/daemon/retry_record"

class RetryRecordTest < Minitest::Test
  def test_validates_and_round_trips_a_cooldown_projection
    record = Hive::Daemon::RetryRecord.new(valid_record)

    assert_equal "cooldown", record.state
    assert_equal 4, record.retry_count
    assert_equal valid_record, record.to_h
  end

  def test_rejects_invalid_states_counts_and_deadlines
    [
      valid_record.merge("state" => "quarantined"),
      valid_record.merge("retry_count" => -1),
      valid_record.merge("retry_after" => nil),
      valid_record.merge("retry_after" => "not-a-time"),
      valid_record.merge("key" => valid_record.fetch("key").merge("generation" => nil))
    ].each do |candidate|
      assert_raises(Hive::Daemon::InvalidRetryRecord) do
        Hive::Daemon::RetryRecord.new(candidate)
      end
    end
  end

  def test_ready_may_have_no_current_attempt_but_running_requires_one
    ready = Hive::Daemon::RetryRecord.new(
      valid_record.merge("state" => "ready", "retry_after" => nil, "current_attempt_id" => nil)
    )
    assert_nil ready.current_attempt_id

    assert_raises(Hive::Daemon::InvalidRetryRecord) do
      Hive::Daemon::RetryRecord.new(
        valid_record.merge("state" => "running", "retry_after" => nil, "current_attempt_id" => nil)
      )
    end
  end

  private

  def valid_record
    {
      "schema" => "hive-retry-record",
      "schema_version" => 1,
      "key" => {
        "project" => "demo",
        "task" => "durable-task",
        "stage" => "4-execute",
        "generation" => 3
      },
      "predecessor_attempt_id" => "attempt-4",
      "current_attempt_id" => nil,
      "retry_count" => 4,
      "failure_class" => "agent_died",
      "failure_code" => "agent_died",
      "evidence" => [ { "kind" => "message", "value" => "worker exited" } ],
      "guidance" => "Inspect the worker log.",
      "first_failure_at" => "2026-07-17T10:00:00.000000Z",
      "last_failure_at" => "2026-07-17T10:03:00.000000Z",
      "retry_after" => "2026-07-17T10:08:00.000000Z",
      "state" => "cooldown",
      "authorization" => nil,
      "operator" => nil,
      "last_event_id" => "retry-event-4"
    }
  end
end
