require "test_helper"
require "hive/tui/bubble_model"

# Pin the BubbleModel adapter's translation/dispatch contract:
# framework messages → Hive Messages, KeyMessage → KeyMap.message_for,
# DispatchCommand → takeover_command, sub-mode entries set state.
# Excludes the side-effect handlers that need real subprocesses
# (toggle_finding/bulk_*) — those are exercised by integration tests.
class HiveTuiBubbleModelTest < Minitest::Test
  include HiveTestHelper

  def setup
    @messages = []
    @dispatch = ->(m) { @messages << m }
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch
    )
  end

  # ---- Construction / init ----

  def test_init_returns_self_and_yield_tick
    new_model, cmd = @model.init
    assert_same @model, new_model
    # init seeds a recurring YieldTick so background threads (StateSource
    # snapshot polling) get GVL time between bubbletea's input polls.
    assert_kind_of Bubbletea::TickCommand, cmd,
      "init must seed the yield tick so the GVL-yield cycle starts"
  end

  def test_yield_tick_message_reschedules_a_fresh_tick
    # Once the yield-tick cycle is running, every YieldTick observation
    # must produce a fresh TickCommand or the cycle stalls.
    _, cmd = @model.update(Hive::Tui::Messages::YIELD_TICK)
    assert_kind_of Bubbletea::TickCommand, cmd,
      "update on YieldTick must return a fresh tick to keep the cycle going"
  end

  # ---- WindowSizeMessage translation ----

  def test_window_size_message_translates_to_window_sized
    msg = Bubbletea::WindowSizeMessage.new(width: 120, height: 40)
    @model.update(msg)
    assert_equal 120, @model.hive_model.cols
    assert_equal 40, @model.hive_model.rows
  end

  # ---- KeyMessage → KeyMap.message_for translation ----

  def test_q_keystroke_dispatches_terminate
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "q".ord ])
    _, cmd = @model.update(km)
    # Bubbletea.quit is a Bubbletea::QuitCommand
    assert_kind_of Bubbletea::QuitCommand, cmd
  end

  def test_question_mark_opens_help
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "?".ord ])
    @model.update(km)
    assert_equal :help, @model.hive_model.mode
  end

  def test_slash_opens_filter_prompt
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "/".ord ])
    @model.update(km)
    assert_equal :filter, @model.hive_model.mode
  end

  def test_digit_keystroke_sets_project_scope
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "2".ord ])
    @model.update(km)
    assert_equal 2, @model.hive_model.scope
  end

  def test_unknown_keystroke_is_noop
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "x".ord ])
    snapshot_before = @model.hive_model
    _, cmd = @model.update(km)
    assert_nil cmd
    assert_equal snapshot_before.mode, @model.hive_model.mode,
      "unknown keystrokes must not flip mode"
  end

  # ---- View dispatch by mode ----

  def test_view_renders_grid_in_grid_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "hive tui"
  end

  def test_view_renders_help_overlay_in_help_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :help),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "hive tui — keybindings"
  end

  def test_view_composes_filter_prompt_onto_grid_in_filter_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "auth"),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "/auth"
  end

  # ---- DispatchCommand → background spawn ----

  def test_dispatch_command_message_returns_nil_cmd_and_does_not_block
    # Background dispatch returns nil — the TUI keeps its render loop
    # going while the agent runs in parallel. The reaper Thread sends
    # SubprocessExited later via the `dispatch` lambda.
    started = Time.now
    msg = Hive::Tui::Messages::DispatchCommand.new(argv: [ "echo", "hi" ], verb: "hi")
    _, cmd = @model.update(msg)
    elapsed = Time.now - started
    assert_nil cmd, "DispatchCommand spawns in the background; no Bubbletea Cmd returned"
    assert elapsed < 0.5,
      "update must NOT block on the spawn (got #{elapsed}s — should be < 0.5s)"
  end

  # ---- Late-binding dispatch (so App.run_charm can wire runner.method(:send)) ----

  def test_dispatch_setter_replaces_callable
    new_dispatch = ->(_m) { }
    @model.dispatch = new_dispatch
    # The replacement dispatch is now what the background reaper would
    # dispatch SubprocessExited through. Smoke check: the call doesn't
    # raise (returns nil cmd just like any DispatchCommand).
    msg = Hive::Tui::Messages::DispatchCommand.new(argv: [ "echo" ], verb: nil)
    _, cmd = @model.update(msg)
    assert_nil cmd
  end

  # ---- Side-effect handlers must not propagate file-system exceptions ----
  #
  # The TUI runs inside `Bubbletea::Runner.run`; an unhandled exception
  # from `BubbleModel#update` unwinds out of the runner and tears down
  # the alt-screen mid-frame, leaving the user's terminal in a corrupt
  # state. Every side-effect handler that does I/O must therefore rescue
  # the predictable failure modes and surface them as a flash, never
  # raise.
  #
  # The dogfood-found regression: pressing Enter on an `error`-state
  # row whose task hadn't run any agent yet (logs/ dir empty) made
  # `LogTail::FileResolver.latest` raise `Hive::NoLogFiles`, which
  # wasn't in `open_log_tail`'s rescue list, killing the TUI.

  # ---- Auto-heal: kill-class error markers (SIGINT/SIGKILL/SIGTERM) ----
  #
  # When `hive pr` (or any takeover) gets killed mid-spawn — pgroup
  # forwards SIGTERM, the agent writes `:error reason=exit_code
  # exit_code=143`, and the task folder is left intact — the file
  # state IS recoverable but the marker says "Error". Auto-heal
  # clears those markers in the background so the TUI doesn't strand
  # interrupted tasks in a stuck "Error" classification the user has
  # to manually escape from.

  def make_error_row(slug:, folder:, exit_code:, reason: "exit_code")
    Hive::Tui::Snapshot::Row.new(
      project_name: "demo", stage: "5-review", slug: slug, folder: folder,
      state_file: nil, marker: "error", attrs: { "reason" => reason, "exit_code" => exit_code.to_s },
      mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "error", action_label: "Error", suggested_command: nil
    )
  end

  def stub_heal_capture(model)
    captured = []
    model.define_singleton_method(:spawn_heal_thread) { |row| captured << row.folder }
    captured
  end

  def snapshot_with(rows)
    project = Hive::Tui::Snapshot::ProjectView.new(
      name: "demo", path: "/x", hive_state_path: "/x/.hive-state",
      error: nil, rows: rows.freeze
    ).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ project ])
  end

  def test_snapshot_with_sigterm_error_triggers_heal
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "killed", folder: "/x/.hive-state/stages/5-review/killed", exit_code: 143) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/.hive-state/stages/5-review/killed" ], captured,
      "sigterm-killed task must trigger one heal"
  end

  def test_snapshot_with_sigint_error_triggers_heal
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "ctrlc", folder: "/x/.hive-state/stages/4-execute/ctrlc", exit_code: 130) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/.hive-state/stages/4-execute/ctrlc" ], captured
  end

  def test_snapshot_with_sigkill_error_triggers_heal
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "killed9", folder: "/x/.hive-state/stages/4-execute/killed9", exit_code: 137) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/.hive-state/stages/4-execute/killed9" ], captured
  end

  def test_snapshot_with_real_failure_does_not_heal
    # exit_code=1 is a normal program exit, not a signal kill — the
    # agent decided to fail. Auto-heal MUST NOT clear these; the
    # error reflects a real condition the user needs to inspect.
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "real-fail", folder: "/x/y", exit_code: 1) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_empty captured, "exit_code=1 is a real failure, must not auto-heal"
  end

  def test_snapshot_with_non_exit_code_error_does_not_heal
    # `:error reason=timeout` or `:error reason=secret_in_pr_body`
    # are real, structured errors — clearing them silently would
    # mask actual problems.
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "timeout", folder: "/x/y", exit_code: nil, reason: "timeout") ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_empty captured
  end

  def test_heal_dedup_only_fires_once_per_folder
    captured = stub_heal_capture(@model)
    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/5-review/killed", exit_code: 143)
    snap = snapshot_with([ row ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length,
      "repeated snapshots with the same kill-class error must trigger ONE heal, not N"
  end

  def test_snapshot_arrived_still_updates_the_model_after_auto_heal
    stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "k", folder: "/x/y", exit_code: 143) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_same snap, @model.hive_model.snapshot,
      "auto-heal must not block the regular Update.apply path — the model still updates"
  end

  # Last-resort safety net: an unhandled exception escaping
  # `BubbleModel#update` would unwind out of Bubbletea's runner and
  # tear down the alt-screen mid-frame. Pin that ANY StandardError
  # is converted into a flash + the TUI keeps running.
  def test_unhandled_exception_in_handler_becomes_flash_not_crash
    # Force OpenLogTail to hit an unanticipated Errno by passing a
    # row whose folder is a path that File operations will reject
    # for a reason NOT in the explicit rescue list (Errno::ENAMETOOLONG
    # via a folder name >255 bytes — neither ENOENT nor EACCES).
    crash_row = Hive::Tui::Snapshot::Row.new(
      project_name: "x", stage: "5-review", slug: "demo",
      folder: "/" + ("a" * 4096), state_file: nil, marker: nil, attrs: nil,
      mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "error", action_label: "Error", suggested_command: nil
    )

    # Whatever exception rises (InvalidTaskPath from the bad folder
    # is the actual one here, but the safety net should catch any
    # StandardError) — must not propagate.
    _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: crash_row))
    assert_nil cmd, "unhandled exception path returns nil cmd, never propagates"
    refute_nil @model.hive_model.flash, "exception must be surfaced as a flash"
    assert_equal :grid, @model.hive_model.mode,
      "exception in a sub-mode entry must NOT leave mode flipped"
  end

  def test_open_log_tail_flashes_when_no_log_files_exist
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "demo-260426-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "5-review", slug)
      FileUtils.mkdir_p(File.join(task_folder, "logs")) # logs dir but NO *.log files

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "5-review", slug: slug,
        folder: task_folder, state_file: nil, marker: nil, attrs: nil,
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "error", action_label: "Error", suggested_command: nil
      )

      # Must not raise — must convert NoLogFiles into a flashed model
      # change so the TUI keeps running.
      _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: row))
      assert_nil cmd, "no Cmd returned for the no-logs case"
      assert_match(/no logs yet for #{slug}/, @model.hive_model.flash)
      assert_equal :grid, @model.hive_model.mode,
        "must stay in grid mode, not flip to :log_tail with a missing log"
    end
  end
end
