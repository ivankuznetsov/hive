require "test_helper"
require "tmpdir"
require "hive/tui/bubble_model"
require "hive/update_check/state"

# Pins the TUI footer's update-nudge read path (plan 2026-05-27-002, U5):
# the model surfaces the daemon-written nudge and degrades to nil when absent.
class HiveTuiBubbleModelUpdateNudgeTest < Minitest::Test
  include HiveTestHelper

  def setup
    @dir = Dir.mktmpdir
    @state = Hive::UpdateCheck::State.new(path: File.join(@dir, "update_check.json"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def model
    Hive::Tui::BubbleModel.new(update_state: @state)
  end

  def test_no_nudge_when_state_empty
    assert_nil model.send(:update_nudge)
  end

  def test_reads_daemon_written_nudge
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade ivankuznetsov/hive/hive")
    nudge = model.send(:update_nudge)
    assert nudge
    assert_equal "0.1.7", nudge.latest
  end

  def test_nudge_label_format
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade ivankuznetsov/hive/hive")
    m = model
    label = m.send(:update_nudge_label, m.send(:update_nudge))
    assert_equal "update 0.1.7: brew upgrade ivankuznetsov/hive/hive", label
  end

  def test_read_is_cached_within_ttl
    m = model
    assert_nil m.send(:update_nudge)
    # A nudge written after the first (cached) read is not seen until the TTL
    # lapses — proves the footer doesn't re-read the file every frame.
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade x")
    assert_nil m.send(:update_nudge), "within TTL the cached (nil) value is returned"
  end

  def test_nudge_refreshes_after_ttl_expires
    m = model
    assert_nil m.send(:update_nudge) # caches nil at "now"
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade x")
    # Age the cached check timestamp past the TTL window so the next read
    # re-reads the file and picks up the newly-written nudge.
    stale = Process.clock_gettime(Process::CLOCK_MONOTONIC) - (Hive::Tui::BubbleModel::UPDATE_NUDGE_TTL_SEC + 5)
    m.instance_variable_set(:@update_nudge_checked_at, stale)
    nudge = m.send(:update_nudge)
    assert nudge, "cache must refresh once the TTL window elapses"
    assert_equal "0.1.7", nudge.latest
  end

  def test_update_nudge_swallows_state_errors
    boom = Object.new
    def boom.nudge = raise(StandardError, "state boom")
    m = Hive::Tui::BubbleModel.new(update_state: boom)
    assert_nil m.send(:update_nudge), "a raising state must degrade the footer to no-nudge, not crash"
  end

  def test_update_check_state_swallows_construction_errors
    m = Hive::Tui::BubbleModel.new(update_state: nil)
    with_replaced_singleton_method(Hive::UpdateCheck::State, :new, ->(*_a, **_k) { raise "no state" }) do
      assert_nil m.send(:update_check_state), "a failed lazy State construction degrades to nil"
    end
  end
end
