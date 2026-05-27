require "test_helper"
require "tmpdir"
require "hive/update_check/state"

class UpdateCheckStateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "update_check.json")
    @now = Time.utc(2026, 5, 27, 12, 0, 0)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def state
    Hive::UpdateCheck::State.new(path: @path)
  end

  def test_due_when_never_checked
    assert state.due?(@now)
  end

  def test_not_due_within_window
    s = state
    s.record_check!(@now)
    refute state.due?(@now + 3600, window: 86_400), "should not be due an hour after a check"
  end

  def test_due_after_window_elapses
    s = state
    s.record_check!(@now)
    assert state.due?(@now + 90_000, window: 86_400), "should be due once the window has elapsed"
  end

  def test_should_notify_once_per_version
    s = state
    assert s.should_notify?("0.1.7")
    s.record_notified!("0.1.7")
    refute state.should_notify?("0.1.7"), "must not re-notify the same version after a restart"
    assert state.should_notify?("0.1.8"), "a newer version is notifiable again"
  end

  def test_nudge_roundtrip_and_clear
    s = state
    s.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade ivankuznetsov/hive/hive")
    n = state.nudge
    assert_equal "0.1.7", n.latest
    assert_equal "brew", n.channel
    assert_equal "brew upgrade ivankuznetsov/hive/hive", n.command

    s.clear_nudge!
    assert_nil state.nudge
  end

  def test_nudge_nil_when_unset
    assert_nil state.nudge
  end

  def test_corrupt_file_degrades_to_empty
    File.write(@path, "{ not valid json")
    s = state
    assert s.due?(@now), "corrupt state should behave as a fresh (due) state"
    assert_nil s.nudge
  end

  def test_wrong_schema_version_degrades_to_empty
    File.write(@path, JSON.generate({ "schema_version" => 99, "last_notified_version" => "9.9.9" }))
    assert state.should_notify?("0.1.7"), "incompatible schema must not leak stale notified-version"
  end

  def test_persists_across_instances
    state.record_check!(@now)
    refute state.due?(@now + 10, window: 86_400), "check timestamp must survive a reload"
  end
end
