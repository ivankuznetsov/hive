require "test_helper"
require "hive/tui/model"
require "hive/tui/messages"
require "hive/tui/update"

# Hive::Tui::Update is the MVU dispatcher: (Model, Message) → [Model, Cmd].
# These tests pin every Message → Update branch as a pure function call,
# without entering the Bubbletea runtime or rendering anything.
class HiveTuiUpdateTest < Minitest::Test
  include HiveTestHelper

  def model
    @model ||= Hive::Tui::Model.initial
  end

  # ---------- WindowSized ----------

  def test_window_sized_updates_dimensions
    new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::WindowSized.new(cols: 120, rows: 40))
    assert_equal 120, new_model.cols
    assert_equal 40, new_model.rows
    assert_nil cmd, "WindowSized has no side-effect Cmd"
  end

  # ---------- SnapshotArrived ----------

  def test_snapshot_arrived_replaces_snapshot_and_clears_last_error
    fake_snapshot = Object.new
    starting = model.with(last_error: StandardError.new("stale"))
    new_model, cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: fake_snapshot)
    )
    assert_same fake_snapshot, new_model.snapshot
    assert_nil new_model.last_error, "successful poll must clear last_error so the stalled banner stops showing"
    assert_nil cmd
  end

  # ---------- PollFailed ----------

  def test_poll_failed_records_error_and_keeps_prior_snapshot
    prior_snapshot = Object.new
    starting = model.with(snapshot: prior_snapshot)
    err = StandardError.new("boom")
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::PollFailed.new(error: err)
    )
    assert_same err, new_model.last_error
    assert_same prior_snapshot, new_model.snapshot,
                "failed poll must keep prior snapshot so the user keeps seeing data"
  end

  # ---------- SubprocessExited ----------

  def test_subprocess_exited_zero_is_silent
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 0)
    )
    assert_nil new_model.flash, "exit 0 must NOT set a flash (success path is silent)"
    assert_nil new_model.flash_set_at
  end

  def test_subprocess_exited_nonzero_sets_flash_with_exit_code
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 4)
    )
    assert_equal "`pr` exited 4", new_model.flash
    refute_nil new_model.flash_set_at, "non-zero exit must stamp flash_set_at for TTL aging"
  end

  def test_subprocess_exited_nil_exit_code_is_silent
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: nil)
    )
    assert_nil new_model.flash
  end

  # ---------- Tick (flash TTL aging) ----------

  def test_tick_clears_expired_flash
    starting = model.with(flash: "old", flash_set_at: Time.now - 10.0)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::TICK)
    assert_nil new_model.flash, "expired flash must clear so the hint footer returns"
    assert_nil new_model.flash_set_at
  end

  def test_tick_preserves_active_flash
    fresh_set_at = Time.now - 1.0
    starting = model.with(flash: "fresh", flash_set_at: fresh_set_at)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::TICK)
    assert_equal "fresh", new_model.flash
    assert_equal fresh_set_at, new_model.flash_set_at
  end

  def test_tick_is_noop_when_no_flash
    new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::TICK)
    assert_nil new_model.flash
    assert_nil cmd
  end

  # ---------- TerminateRequested ----------

  def test_terminate_requested_returns_quit_command
    _new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::TERMINATE_REQUESTED)
    # In tests Bubbletea isn't loaded; Update returns a sentinel. In
    # production (App.run_charm requires Bubbletea), the same call
    # returns Bubbletea.quit. Either way: not nil, signals exit.
    refute_nil cmd
  end

  def test_terminate_requested_does_not_mutate_model
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::TERMINATE_REQUESTED)
    assert_same model, new_model
  end

  # ---------- FilterCharAppended ----------

  def test_filter_char_appended_extends_buffer
    starting = model.with(filter_buffer: "au")
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::FilterCharAppended.new(char: "t")
    )
    assert_equal "aut", new_model.filter_buffer
  end

  def test_filter_char_appended_works_on_empty_buffer
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::FilterCharAppended.new(char: "a")
    )
    assert_equal "a", new_model.filter_buffer
  end

  # ---------- FilterCharDeleted ----------

  def test_filter_char_deleted_shrinks_buffer
    starting = model.with(filter_buffer: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_CHAR_DELETED)
    assert_equal "aut", new_model.filter_buffer
  end

  def test_filter_char_deleted_on_empty_buffer_is_noop
    starting = model.with(filter_buffer: "")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_CHAR_DELETED)
    assert_equal "", new_model.filter_buffer
  end

  # ---------- FilterCommitted ----------

  def test_filter_committed_promotes_buffer_to_active_filter_and_returns_to_grid
    starting = model.with(mode: :filter, filter_buffer: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_COMMITTED)
    assert_equal "auth", new_model.filter
    assert_equal "", new_model.filter_buffer
    assert_equal :grid, new_model.mode
  end

  def test_filter_committed_with_empty_buffer_clears_active_filter
    starting = model.with(mode: :filter, filter: "old", filter_buffer: "")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_COMMITTED)
    assert_nil new_model.filter, "committing an empty buffer must clear any prior active filter"
  end

  # ---------- FilterCancelled ----------

  def test_filter_cancelled_returns_to_grid_and_clears_buffer
    starting = model.with(mode: :filter, filter_buffer: "wip", filter: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_CANCELLED)
    assert_equal :grid, new_model.mode
    assert_equal "", new_model.filter_buffer
    # Esc preserves any previously-committed filter — the user clears
    # it via a separate keystroke in grid mode (the existing curses
    # behavior).
    assert_equal "auth", new_model.filter
  end

  # ---------- KeyPressed (stub) ----------

  def test_key_pressed_is_a_noop_in_u4_skeleton
    # KeyPressed handling lands in U5 once KeyMap returns Messages.
    # The U4 skeleton must not raise on KeyPressed — it returns the
    # model unchanged with no Cmd.
    new_model, cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::KeyPressed.new(key: "q")
    )
    assert_same model, new_model
    assert_nil cmd
  end

  # ---------- Unknown messages ----------

  def test_unknown_message_class_is_ignored
    # Future-compat: framework messages we don't dispatch on yet
    # (FocusMessage, BlurMessage, MouseMessage if mouse ever enables)
    # should pass through cleanly rather than raising.
    unknown = Class.new.new
    new_model, cmd = Hive::Tui::Update.apply(model, unknown)
    assert_same model, new_model
    assert_nil cmd
  end

  # ---------- Pure-function discipline ----------

  def test_apply_does_not_mutate_input_model
    starting = model.with(snapshot: Object.new)
    Hive::Tui::Update.apply(starting, Hive::Tui::Messages::WindowSized.new(cols: 99, rows: 33))
    assert_equal 80, starting.cols, "Update must not mutate the input model"
    assert_equal 24, starting.rows
  end

  # ---------- Keystroke-derived handlers (U10) ----------

  require "hive/tui/snapshot"

  def snap_with_two_projects_three_rows_each
    rows_a = (1..3).map do |i|
      Hive::Tui::Snapshot::Row.new(
        project_name: "alpha", stage: "1-input", slug: "a#{i}", folder: nil,
        state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
        action_label: "ready to brainstorm", suggested_command: "hive brainstorm a#{i}"
      ).freeze
    end
    rows_b = (1..3).map do |i|
      Hive::Tui::Snapshot::Row.new(
        project_name: "beta", stage: "1-input", slug: "b#{i}", folder: nil,
        state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
        action_label: "ready to brainstorm", suggested_command: "hive brainstorm b#{i}"
      ).freeze
    end
    pa = Hive::Tui::Snapshot::ProjectView.new(name: "alpha", path: "/a", hive_state_path: "/a/.h", error: nil, rows: rows_a.freeze).freeze
    pb = Hive::Tui::Snapshot::ProjectView.new(name: "beta",  path: "/b", hive_state_path: "/b/.h", error: nil, rows: rows_b.freeze).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ pa, pb ])
  end

  def test_flash_message_sets_flash_with_timestamp
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::Flash.new(text: "hello"))
    assert_equal "hello", new_model.flash
    refute_nil new_model.flash_set_at
  end

  def test_cursor_down_moves_within_project
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 0, 1 ], new_model.cursor
  end

  def test_cursor_down_jumps_to_next_project_at_last_row
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 2 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 1, 0 ], new_model.cursor
  end

  def test_cursor_down_clamps_at_end_of_last_project
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 1, 2 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 1, 2 ], new_model.cursor, "must clamp rather than wrap"
  end

  def test_cursor_up_jumps_to_previous_project_at_first_row
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 1, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal [ 0, 2 ], new_model.cursor
  end

  def test_cursor_up_clamps_at_top
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal [ 0, 0 ], new_model.cursor
  end

  def test_show_help_sets_mode_to_help
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::SHOW_HELP)
    assert_equal :help, new_model.mode
  end

  def test_open_filter_prompt_pre_fills_buffer_with_active_filter
    starting = model.with(filter: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::OPEN_FILTER_PROMPT)
    assert_equal :filter, new_model.mode
    assert_equal "auth", new_model.filter_buffer
  end

  def test_back_from_triage_clears_triage_state
    starting = model.with(mode: :triage, triage_state: Object.new)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)
    assert_equal :grid, new_model.mode
    assert_nil new_model.triage_state
  end

  def test_back_from_log_tail_clears_tail_state
    starting = model.with(mode: :log_tail, tail_state: Object.new)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)
    assert_equal :grid, new_model.mode
    assert_nil new_model.tail_state
  end

  def test_back_from_help_returns_to_grid
    starting = model.with(mode: :help)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)
    assert_equal :grid, new_model.mode
  end

  def test_project_scope_sets_scope_and_resets_cursor
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 2 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::ProjectScope.new(n: 2))
    assert_equal 2, new_model.scope
    assert_equal [ 0, 0 ], new_model.cursor
  end

  def test_project_scope_zero_clears_scope
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, scope: 1)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::ProjectScope.new(n: 0))
    assert_equal 0, new_model.scope
  end

  def test_noop_returns_model_unchanged
    new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::NOOP)
    assert_same model, new_model
    assert_nil cmd
  end
end
