require "test_helper"
require "hive/tui/model"
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

  def test_subprocess_exited_carries_verb_exit_code_and_optional_spawn_id
    msg = Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 4)
    assert_equal "pr", msg.verb
    assert_equal 4, msg.exit_code
    assert_nil msg.spawn_id

    msg = Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 4, spawn_id: "deadbeef")
    assert_equal "deadbeef", msg.spawn_id
  end

  def test_input_editor_exited_carries_edit_result
    msg = Hive::Tui::Messages::InputEditorExited.new(
      slug: "idea-260504-a1b2",
      exit_code: 0,
      changed: true
    )
    assert_equal "idea-260504-a1b2", msg.slug
    assert_equal 0, msg.exit_code
    assert_equal true, msg.changed
  end

  def test_open_input_editor_carries_row
    row = Object.new
    msg = Hive::Tui::Messages::OpenInputEditor.new(row: row)
    assert_same row, msg.row
  end

  def test_open_idea_preview_carries_row
    row = Object.new
    msg = Hive::Tui::Messages::OpenIdeaPreview.new(row: row)

    assert_same row, msg.row
    assert_includes Hive::Tui::Messages::OpenIdeaPreview.members, :row
  end

  def test_open_in_agent_carries_row
    row = Object.new
    msg = Hive::Tui::Messages::OpenInAgent.new(row: row)
    assert_same row, msg.row
    assert msg.frozen?, "Data.define records must be frozen"
  end

  def test_open_in_agent_requires_row
    assert_raises(ArgumentError) { Hive::Tui::Messages::OpenInAgent.new }
  end

  def test_token_stats_singletons_are_frozen
    assert Hive::Tui::Messages::OPEN_TOKEN_STATS.frozen?
    assert_kind_of Hive::Tui::Messages::OpenTokenStats,
                   Hive::Tui::Messages::OPEN_TOKEN_STATS
    assert Hive::Tui::Messages::CLOSE_TOKEN_STATS.frozen?
    assert_kind_of Hive::Tui::Messages::CloseTokenStats,
                   Hive::Tui::Messages::CLOSE_TOKEN_STATS
  end

  def test_token_stats_navigation_messages_carry_direction
    scope = Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :in)
    selection = Hive::Tui::Messages::TokenStatsSelectionMoved.new(direction: :previous)

    assert_equal :in, scope.direction
    assert_equal :previous, selection.direction
  end

  def test_drop_focused_task_carries_row
    row = Object.new
    msg = Hive::Tui::Messages::DropFocusedTask.new(row: row)

    assert_same row, msg.row
    assert msg.frozen?, "Data.define records must be frozen"
  end

  def test_agent_steer_exited_carries_exit_context
    msg = Hive::Tui::Messages::AgentSteerExited.new(
      slug: "manual-task",
      folder: "/tmp/hive/.hive-state/stages/4-execute/manual-task",
      exit_code: 0,
      worktree: "/tmp/hive.worktrees/manual-task"
    )

    assert_equal "manual-task", msg.slug
    assert_equal "/tmp/hive/.hive-state/stages/4-execute/manual-task", msg.folder
    assert_equal 0, msg.exit_code
    assert_equal "/tmp/hive.worktrees/manual-task", msg.worktree
    assert msg.frozen?, "Data.define records must be frozen"
  end

  def test_agent_steer_exited_requires_all_fields
    assert_raises(ArgumentError) do
      Hive::Tui::Messages::AgentSteerExited.new(slug: "manual-task", folder: "/tmp/f")
    end
  end

  def test_recover_review_carries_row
    row = Object.new
    msg = Hive::Tui::Messages::RecoverReview.new(row: row)
    assert_same row, msg.row
  end

  def test_recover_error_carries_row
    row = Object.new
    msg = Hive::Tui::Messages::RecoverError.new(row: row)
    assert_same row, msg.row
  end

  def test_red_status_detail_messages_carry_row
    row = Object.new
    assert_same row, Hive::Tui::Messages::OpenRedStatusDetail.new(row: row).row
    assert_same row, Hive::Tui::Messages::RedStatusAutofix.new(row: row).row
  end

  def test_red_status_detail_scroll_carries_direction_and_amount
    msg = Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :up, amount: 10)

    assert_equal :up, msg.direction
    assert_equal 10, msg.amount
  end

  def test_help_scroll_carries_direction_and_amount
    msg = Hive::Tui::Messages::HelpScroll.new(direction: :down, amount: 3)

    assert_equal :down, msg.direction
    assert_equal 3, msg.amount
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

  def test_raw_text_input_carries_text_and_paste_flag
    msg = Hive::Tui::Messages::RawTextInput.new(text: "hello", paste: true)
    assert_equal "hello", msg.text
    assert_equal true, msg.paste
  end

  def test_filter_text_inserted_carries_text
    msg = Hive::Tui::Messages::FilterTextInserted.new(text: "auth flow")
    assert_equal "auth flow", msg.text
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

  def test_new_idea_text_inserted_carries_text
    msg = Hive::Tui::Messages::NewIdeaTextInserted.new(text: "rss feeds")
    assert_equal "rss feeds", msg.text
  end

  def test_new_idea_paste_requested_carries_raw_text
    msg = Hive::Tui::Messages::NewIdeaPasteRequested.new(raw_text: "/tmp/shot.png")
    assert_equal "/tmp/shot.png", msg.raw_text
  end

  def test_new_idea_image_attached_has_data_equality
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1",
      staging_path: "/tmp/image-1.png",
      ext: "png"
    )
    a = Hive::Tui::Messages::NewIdeaImageAttached.new(
      attachment: attachment
    )
    b = Hive::Tui::Messages::NewIdeaImageAttached.new(
      attachment: attachment
    )

    assert_equal a, b
    assert_equal attachment, a.attachment
  end

  def test_new_idea_image_attached_requires_attachment_record
    err = assert_raises(ArgumentError) do
      Hive::Tui::Messages::NewIdeaImageAttached.new(attachment: Object.new)
    end

    assert_match(/Attachment/, err.message)
  end

  def test_new_idea_singletons_are_frozen
    assert Hive::Tui::Messages::NEW_IDEA_CURSOR_LEFT.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CURSOR_RIGHT.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CURSOR_HOME.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CURSOR_END.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED_FORWARD.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_DOWN.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_UP.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_SUBMITTED.frozen?
    assert Hive::Tui::Messages::NEW_IDEA_CANCELLED.frozen?
  end

  def test_new_idea_singleton_classes
    assert_kind_of Hive::Tui::Messages::NewIdeaCursorLeft,
                   Hive::Tui::Messages::NEW_IDEA_CURSOR_LEFT
    assert_kind_of Hive::Tui::Messages::NewIdeaCursorRight,
                   Hive::Tui::Messages::NEW_IDEA_CURSOR_RIGHT
    assert_kind_of Hive::Tui::Messages::NewIdeaCursorHome,
                   Hive::Tui::Messages::NEW_IDEA_CURSOR_HOME
    assert_kind_of Hive::Tui::Messages::NewIdeaCursorEnd,
                   Hive::Tui::Messages::NEW_IDEA_CURSOR_END
    assert_kind_of Hive::Tui::Messages::NewIdeaCharDeleted,
                   Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED
    assert_kind_of Hive::Tui::Messages::NewIdeaCharDeletedForward,
                   Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED_FORWARD
    assert_kind_of Hive::Tui::Messages::NewIdeaProjectCursorDown,
                   Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_DOWN
    assert_kind_of Hive::Tui::Messages::NewIdeaProjectCursorUp,
                   Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_UP
    assert_kind_of Hive::Tui::Messages::NewIdeaProjectSelected,
                   Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED
    assert_kind_of Hive::Tui::Messages::NewIdeaSubmitted,
                   Hive::Tui::Messages::NEW_IDEA_SUBMITTED
    assert_kind_of Hive::Tui::Messages::NewIdeaCancelled,
                   Hive::Tui::Messages::NEW_IDEA_CANCELLED
  end
end
