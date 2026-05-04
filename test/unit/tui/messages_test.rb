require "test_helper"
require "hive/tui/messages"

# Hive::Tui::Messages is the closed enum of MVU messages. Pure data —
# these tests pin the field shapes and the singleton-instance pattern
# used by parameterless messages.
class HiveTuiMessagesTest < Minitest::Test
  include HiveTestHelper

  def test_key_pressed_carries_key
    msg = Hive::Tui::Messages::KeyPressed.new(key: "q")
    assert_equal "q", msg.key
  end

  def test_key_pressed_accepts_symbol_keys
    msg = Hive::Tui::Messages::KeyPressed.new(key: :key_enter)
    assert_equal :key_enter, msg.key
  end

  def test_snapshot_arrived_carries_snapshot
    fake_snapshot = Object.new
    msg = Hive::Tui::Messages::SnapshotArrived.new(snapshot: fake_snapshot)
    assert_same fake_snapshot, msg.snapshot
  end

  def test_poll_failed_carries_error
    err = StandardError.new("boom")
    msg = Hive::Tui::Messages::PollFailed.new(error: err)
    assert_same err, msg.error
  end

  def test_window_sized_carries_dimensions
    msg = Hive::Tui::Messages::WindowSized.new(cols: 100, rows: 30)
    assert_equal 100, msg.cols
    assert_equal 30, msg.rows
  end

  def test_subprocess_exited_carries_verb_and_exit_code
    msg = Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 4)
    assert_equal "pr", msg.verb
    assert_equal 4, msg.exit_code
  end

  def test_terminate_requested_singleton
    # Parameterless messages use a frozen singleton so callers don't
    # allocate per-trigger and so identity comparisons work.
    assert Hive::Tui::Messages::TERMINATE_REQUESTED.frozen?
    assert_kind_of Hive::Tui::Messages::TerminateRequested,
                   Hive::Tui::Messages::TERMINATE_REQUESTED
  end

  def test_tick_singleton
    assert Hive::Tui::Messages::TICK.frozen?
    assert_kind_of Hive::Tui::Messages::Tick, Hive::Tui::Messages::TICK
  end

  def test_filter_char_appended_carries_char
    msg = Hive::Tui::Messages::FilterCharAppended.new(char: "a")
    assert_equal "a", msg.char
  end

  def test_filter_singletons_are_frozen
    assert Hive::Tui::Messages::FILTER_CHAR_DELETED.frozen?
    assert Hive::Tui::Messages::FILTER_COMMITTED.frozen?
    assert Hive::Tui::Messages::FILTER_CANCELLED.frozen?
  end

  def test_filter_singleton_classes
    assert_kind_of Hive::Tui::Messages::FilterCharDeleted,
                   Hive::Tui::Messages::FILTER_CHAR_DELETED
    assert_kind_of Hive::Tui::Messages::FilterCommitted,
                   Hive::Tui::Messages::FILTER_COMMITTED
    assert_kind_of Hive::Tui::Messages::FilterCancelled,
                   Hive::Tui::Messages::FILTER_CANCELLED
  end

  def test_data_messages_are_frozen
    msg = Hive::Tui::Messages::KeyPressed.new(key: "q")
    assert msg.frozen?, "Data.define records must be frozen"
  end

  # ---- v2 two-pane messages ----

  def test_pane_focus_toggled_singleton
    assert Hive::Tui::Messages::PANE_FOCUS_TOGGLED.frozen?
    assert_kind_of Hive::Tui::Messages::PaneFocusToggled,
                   Hive::Tui::Messages::PANE_FOCUS_TOGGLED
  end

  def test_pane_focus_changed_carries_target
    msg = Hive::Tui::Messages::PaneFocusChanged.new(target: :left)
    assert_equal :left, msg.target
  end

  def test_pane_focus_changed_accepts_right
    msg = Hive::Tui::Messages::PaneFocusChanged.new(target: :right)
    assert_equal :right, msg.target
  end

  def test_open_new_idea_prompt_singleton
    assert Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT.frozen?
    assert_kind_of Hive::Tui::Messages::OpenNewIdeaPrompt,
                   Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT
  end

  def test_new_idea_char_appended_carries_char
    msg = Hive::Tui::Messages::NewIdeaCharAppended.new(char: "r")
    assert_equal "r", msg.char
  end

  def test_new_idea_singletons_are_frozen
    assert Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_SUBMITTED.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CANCELLED.frozen?
  end

  def test_new_idea_singleton_classes
    assert_kind_of Hive::Tui::Messages::NewIdeaCharDeleted,
                   Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED
    assert_kind_of Hive::Tui::Messages::NewIdeaSubmitted,
                   Hive::Tui::Messages::NEW_IDEA_SUBMITTED
    assert_kind_of Hive::Tui::Messages::NewIdeaCancelled,
                   Hive::Tui::Messages::NEW_IDEA_CANCELLED
  end
end
