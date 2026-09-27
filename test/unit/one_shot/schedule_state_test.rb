require "test_helper"
require "hive/one_shot/schedule_state"

class OneShotScheduleStateTest < Minitest::Test
  include HiveTestHelper

  def test_missing_state_initializes_and_updates_preserve_other_components
    with_tmp_dir do |root|
      state = Hive::OneShot::ScheduleState.new(state_root: root)
      assert_equal({}, state.read("patrol"))

      state.update("patrol", now: Time.utc(2026, 9, 23, 12)) do |_current|
        { "post_reserve_at" => "2026-09-23T12:10:00.000000Z" }
      end
      state.update("dispatch", now: Time.utc(2026, 9, 23, 12, 1)) do |_current|
        { "quarantined" => [ "task:1" ] }
      end

      fresh = Hive::OneShot::ScheduleState.new(state_root: root)
      assert_equal "2026-09-23T12:10:00.000000Z", fresh.read("patrol")["post_reserve_at"]
      assert_equal [ "task:1" ], fresh.read("dispatch")["quarantined"]
      assert_equal 0o600, File.stat(fresh.path).mode & 0o777
    end
  end

  def test_updates_merge_under_lock_without_losing_a_sibling_component
    with_tmp_dir do |root|
      first = Hive::OneShot::ScheduleState.new(state_root: root)
      second = Hive::OneShot::ScheduleState.new(state_root: root)
      first.update("patrol") do
        {
          "failure_count" => 1,
          "failure_retry_at" => "2026-09-23T12:05:00Z"
        }
      end
      second.update("architecture_patrol") { { "retry_at" => "2026-09-23T12:10:00Z" } }

      assert_equal 1, first.read("patrol")["failure_count"]
      assert_equal "2026-09-23T12:10:00Z", first.read("architecture_patrol")["retry_at"]
    end
  end

  def test_corrupt_and_newer_state_fail_closed
    with_tmp_dir do |root|
      state = Hive::OneShot::ScheduleState.new(state_root: root)
      FileUtils.mkdir_p(File.dirname(state.path))
      File.binwrite(state.path, "{")
      error = assert_raises(Hive::OneShot::ScheduleState::StateError) { state.read("patrol") }
      assert_equal "checkpoint_corrupt", error.code

      File.binwrite(state.path, JSON.generate(
        "schema" => "hive-scheduler-checkpoint", "schema_version" => 99,
        "updated_at" => "2026-09-23T12:00:00Z", "components" => {}
      ))
      error = assert_raises(Hive::OneShot::ScheduleState::StateError) { state.read("patrol") }
      assert_equal "checkpoint_newer_schema", error.code
    end
  end

  def test_invalid_deadline_and_component_shape_are_rejected_before_write
    with_tmp_dir do |root|
      state = Hive::OneShot::ScheduleState.new(state_root: root)
      error = assert_raises(Hive::OneShot::ScheduleState::StateError) do
        state.update("patrol") { { "retry_at" => "tomorrow" } }
      end
      assert_equal "checkpoint_invalid", error.code
      refute_path_exists state.path

      assert_raises(Hive::OneShot::ScheduleState::StateError) do
        state.update("patrol") { [] }
      end
    end
  end

  def test_invalid_patrol_failure_gate_is_rejected_before_restore_or_write
    with_tmp_dir do |root|
      state = Hive::OneShot::ScheduleState.new(state_root: root)
      FileUtils.mkdir_p(File.dirname(state.path))
      File.binwrite(state.path, JSON.generate(
        "schema" => "hive-scheduler-checkpoint", "schema_version" => 1,
        "updated_at" => "2026-09-23T12:00:00Z",
        "components" => {
          "patrol" => {
            "failure_count" => "invalid",
            "failure_retry_at" => "2026-09-23T12:10:00Z"
          }
        }
      ))

      error = assert_raises(Hive::OneShot::ScheduleState::StateError) do
        state.read("patrol")
      end
      assert_equal "checkpoint_invalid", error.code

      FileUtils.rm_f(state.path)
      error = assert_raises(Hive::OneShot::ScheduleState::StateError) do
        state.update("patrol") do
          { "failure_count" => 1, "failure_retry_at" => nil }
        end
      end
      assert_equal "checkpoint_invalid", error.code
      refute_path_exists state.path

      error = assert_raises(Hive::OneShot::ScheduleState::StateError) do
        state.update("patrol") do
          { "failure_count" => 0, "failure_retry_at" => "2026-09-23T12:10:00Z" }
        end
      end
      assert_equal "checkpoint_invalid", error.code
      refute_path_exists state.path
    end
  end

  def test_lock_and_serialization_failures_are_typed
    with_tmp_dir do |root|
      state = Hive::OneShot::ScheduleState.new(state_root: root)
      blocked_directory = File.join(root, "blocked")
      File.write(blocked_directory, "file")
      state.instance_variable_set(:@directory, blocked_directory)
      assert_equal "checkpoint_unavailable",
                   assert_raises(Hive::OneShot::ScheduleState::StateError) {
                     state.read("patrol")
                   }.code

      serializing = Hive::OneShot::ScheduleState.new(state_root: root)
      error = assert_raises(Hive::OneShot::ScheduleState::StateError) do
        serializing.send(:persist, "bad" => Float::NAN)
      end
      assert_equal "checkpoint_invalid", error.code
    end
  end
end
