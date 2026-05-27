require "test_helper"
require "tmpdir"
require "hive/tui/bubble_model"
require "hive/update_check/state"

# Pins the TUI footer's update-nudge read path (plan 2026-05-27-002, U5):
# the model surfaces the daemon-written nudge and degrades to nil when absent.
class HiveTuiBubbleModelUpdateNudgeTest < Minitest::Test
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
end
