require "test_helper"
require "hive/recovery/api"

class HiveRecoveryAPITest < Minitest::Test
  include HiveTestHelper

  def test_observation_derives_the_state_file_from_a_task_folder
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(folder)
      expected = File.join(folder, "task.md")
      File.write(expected, "# Task\n")

      observation = Hive::Recovery::API.observation(
        { "folder" => folder, "slug" => "task", "stage" => "4-execute" }
      )

      assert_equal expected, observation.state_file
    end
  end

  def test_observation_ignores_invalid_and_unreadable_mtimes
    invalid = Hive::Recovery::API.observation(
      { "state_file_mtime" => "not-a-time" }
    )
    assert_nil invalid.state_file_mtime

    with_tmp_dir do |dir|
      path = File.join(dir, "task.md")
      File.write(path, "# Task\n")
      original = File.method(:mtime)

      with_replaced_singleton_method(File, :mtime, lambda { |candidate|
        raise Errno::EACCES if candidate == path

        original.call(candidate)
      }) do
        unreadable = Hive::Recovery::API.observation({ "state_file" => path })
        assert_nil unreadable.state_file_mtime
      end
    end
  end

  def test_recover_records_request_and_outcome_without_observation_token
    observation_row = {
      "folder" => "/tmp/demo/.hive-state/stages/4-execute/task",
      "slug" => "task", "stage" => "4-execute", "marker" => "ERROR",
      "state_file_mtime" => Time.utc(2026, 8, 12, 12),
      "attempt_id" => "attempt-1", "task_generation" => 3
    }
    records = []
    operation = Object.new
    operation.define_singleton_method(:complete!) { |**args| records << [ :complete, args ] }
    activity = Object.new
    activity.define_singleton_method(:begin_operation) do |**args|
      records << [ :begin, args ]
      operation
    end
    activity.define_singleton_method(:record) { |**args| records << [ :record, args ] }
    coordinator = Object.new
    coordinator.define_singleton_method(:observation_token_for) { |_observation| "a" * 64 }
    coordinator.define_singleton_method(:request) do |**_args|
      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: "queued", request_id: "request-1", attempt_id: nil,
        phase: "admitted", failure_origin: "limits_reached",
        next_eligible_at: "2026-08-12T13:00:00Z", owner: "scheduler",
        reason: nil, remediation: nil, retry_count: 1, provider_hint: nil
      )
    end

    with_replaced_singleton_method(Hive::Recovery::API, :activity_for, ->(*) { activity }) do
      result = Hive::Recovery::API.recover!(
        row: observation_row, coordinator: coordinator,
        now: Time.utc(2026, 8, 12, 12)
      )
      assert_equal "queued", result.status
    end

    assert_equal %i[begin complete record], records.map(&:first)
    refute records.flatten.any? { |value| value == "a" * 64 }
    assert_equal "queued", records.last.last.dig(:payload, "outcome")
  end

  def test_activity_for_builds_from_the_observed_folder
    observation = Hive::Recovery::API.observation(
      { "folder" => "/tmp/task", "state_file" => "/tmp/task/task.md", "slug" => "task" }
    )
    task = Object.new
    activity = Object.new
    seen_clock = nil
    seen_task = nil
    with_replaced_singleton_method(Hive::Task, :new, ->(*) { task }) do
      replacement = lambda do |candidate, clock:|
        seen_task = candidate
        seen_clock = clock
        activity
      end
      with_replaced_singleton_method(Hive::TaskActivity, :for_task, replacement) do
        assert_same activity, Hive::Recovery::API.activity_for(
          observation, now: Time.utc(2026, 8, 12, 12)
        )
      end
    end
    assert_same task, seen_task
    assert_equal Time.utc(2026, 8, 12, 12), seen_clock.call
  end

  def test_recovery_activity_append_failure_is_non_fatal
    observation = Hive::Recovery::API.observation(
      { "folder" => "/tmp/task", "state_file" => "/tmp/task/task.md", "slug" => "task" }
    )
    activity = Object.new
    activity.define_singleton_method(:record) do |**|
      raise Hive::TaskActivity::AppendFailed, "disk unavailable"
    end

    refute Hive::Recovery::API.record_recovery_observation(
      activity, observation, { "status" => "queued" }, now: Time.utc(2026, 8, 12, 12)
    )
  end
end
