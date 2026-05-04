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

  def test_yield_tick_callback_yields_gvl_and_returns_yield_tick_message
    # The callback is the actual GVL-yield mechanism — without
    # `Thread.pass` inside it, the StateSource polling thread starves
    # under bubbletea's tight input-poll loop. This test invokes the
    # callback directly so a regression removing `Thread.pass` (or
    # changing the return value) trips a meaningful failure.
    cmd = @model.send(:yield_tick_cmd)
    callback = cmd.instance_variable_get(:@callback)
    refute_nil callback, "TickCommand must carry an invokable callback"
    result = callback.call
    assert_equal Hive::Tui::Messages::YIELD_TICK, result,
      "callback must return YIELD_TICK so update() reschedules the cycle"
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

  # F2: full filter happy path through KeyMessage → KeyMap → Update.
  # Open filter, type chars, commit; assert filter committed and mode
  # back to :grid. Pins the regression we found in the /ce-code-review
  # walk-through where every filter keystroke silently NOOPed.
  def test_filter_mode_typing_and_enter_commits_filter
    @model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ "/".ord ]))
    "auth".each_char do |c|
      @model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ c.ord ]))
    end
    assert_equal "auth", @model.hive_model.filter_buffer

    @model.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))
    assert_equal "auth", @model.hive_model.filter
    assert_equal :grid, @model.hive_model.mode
    assert_equal "", @model.hive_model.filter_buffer
  end

  def test_filter_mode_backspace_shrinks_buffer
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "auth"),
      dispatch: @dispatch
    )
    @model.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_BACKSPACE))
    assert_equal "aut", @model.hive_model.filter_buffer
  end

  # F16: Esc-in-filter must clear filter_buffer (was leaking the
  # half-typed query into the next `/` open because the message
  # routed through BACK instead of FILTER_CANCELLED).
  def test_filter_mode_escape_clears_buffer_and_returns_to_grid
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "wip", filter: "auth"),
      dispatch: @dispatch
    )
    @model.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ESC))
    assert_equal :grid, @model.hive_model.mode
    assert_equal "", @model.hive_model.filter_buffer
    # Esc preserves any prior committed filter — only clears the
    # in-progress buffer.
    assert_equal "auth", @model.hive_model.filter
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

  # ---- v2 two-pane composition ----

  def test_grid_mode_renders_both_panes_at_full_width
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [
        { "name" => "hive", "tasks" => [
          { "slug" => "fix-cache-x", "stage" => "2-brainstorm", "action" => "ready_to_plan",
            "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
        ] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 100),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "Projects",      "left pane (Projects header) must render at >=70 cols"
    assert_includes out, "★ All projects"
    assert_includes out, "fix-cache-x",   "right pane task row must render"
    assert_includes out, "Tasks ·",       "tasks pane title must render"
    assert_includes out, "[Tab] switch",  "default footer hints must appear"
  end

  def test_grid_mode_collapses_to_single_pane_below_min_cols
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [
        { "name" => "hive", "tasks" => [
          { "slug" => "narrow-task", "stage" => "2-brainstorm", "action" => "ready_to_plan",
            "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
        ] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 60),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "narrow-task", "tasks pane must still render below the threshold"
    refute_includes out, "Projects\n", "Projects pane title must NOT appear when collapsed"
    refute_includes out, "★ All projects\n", "left pane (with ★ prefix) must not render at narrow widths"
  end

  def test_pane_widths_clamps_left_to_18_28_range
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(cols: 200),
      dispatch: @dispatch
    )
    left, right = @model.send(:pane_widths, 200)
    assert_operator left, :>=, 18
    assert_operator left, :<=, 28
    # Right pane reserves a 1-cell margin so the rightmost border
    # glyph never lands in the terminal's last column (some terminals
    # don't reliably render that cell).
    assert_equal 199, left + right
  end

  def test_pane_widths_floors_quarter_with_right_margin
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(cols: 100),
      dispatch: @dispatch
    )
    left, right = @model.send(:pane_widths, 100)
    assert_equal 25, left, "100 * 0.25 = 25; within [18, 28] so no clamp"
    assert_equal 74, right, "right pane reserves 1-cell margin (cols - left - 1)"
  end

  def test_two_pane_min_cols_constant_is_70
    assert_equal 70, Hive::Tui::BubbleModel::TWO_PANE_MIN_COLS
  end

  def test_grid_mode_renders_at_exactly_70_cols
    # Boundary: cols == 70 must use two-pane layout (inclusive on the
    # upper side of the fallback test).
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 70),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "Projects", "70 cols is the inclusive boundary — two-pane must render"
  end

  # Regression for v2 P0: bubble_key_to_keymap previously dropped TAB
  # and SHIFT_TAB on the floor (returned NOOP), making the headline
  # pane-focus toggle silently dead. KeyMap unit tests bypass the
  # translator by passing :key_tab directly, so this lives here at the
  # BubbleModel layer where the bug actually surfaced.
  def test_bubble_key_to_keymap_translates_tab_to_key_tab
    fake_km = Object.new
    fake_km.define_singleton_method(:enter?) { false }
    fake_km.define_singleton_method(:esc?) { false }
    fake_km.define_singleton_method(:up?) { false }
    fake_km.define_singleton_method(:down?) { false }
    fake_km.define_singleton_method(:backspace?) { false }
    fake_km.define_singleton_method(:space?) { false }
    fake_km.define_singleton_method(:tab?) { true }
    fake_km.define_singleton_method(:char) { "" }
    fake_km.define_singleton_method(:key_type) { 0 }
    assert_equal :key_tab, @model.send(:bubble_key_to_keymap, fake_km)
  end

  def test_bubble_key_to_keymap_translates_shift_tab_to_key_backtab
    fake_km = Object.new
    fake_km.define_singleton_method(:enter?) { false }
    fake_km.define_singleton_method(:esc?) { false }
    fake_km.define_singleton_method(:up?) { false }
    fake_km.define_singleton_method(:down?) { false }
    fake_km.define_singleton_method(:backspace?) { false }
    fake_km.define_singleton_method(:space?) { false }
    fake_km.define_singleton_method(:tab?) { false }
    fake_km.define_singleton_method(:char) { "" }
    fake_km.define_singleton_method(:key_type) { Bubbletea::KeyMessage::KEY_SHIFT_TAB }
    assert_equal :key_backtab, @model.send(:bubble_key_to_keymap, fake_km)
  end

  def test_grid_mode_falls_back_at_cols_69_exclusive_boundary
    # The exclusive lower boundary of the two-pane layout. cols = 69
    # must collapse to single-pane (TWO_PANE_MIN_COLS = 70). Without
    # this test only cols=60 (well below) and cols=70 (inclusive) are
    # pinned; a refactor that changes < to <= would slip through.
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [
        { "name" => "hive", "tasks" => [
          { "slug" => "boundary-task", "stage" => "2-brainstorm", "action" => "ready_to_plan",
            "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
        ] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 69),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "boundary-task", "tasks pane must still render at the fallback boundary"
    refute_includes out, "Projects\n", "Projects pane title must NOT appear at cols < 70"
  end

  # Regression: deleting v1 Views::Grid silently dropped the
  # stalled-poll banner — transient StateSource errors became
  # invisible. The v2 composer must surface model.last_error.
  def test_grid_mode_renders_stalled_banner_when_last_error_set
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    err = StandardError.new("connection refused")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :grid, snapshot: snap, cols: 100, last_error: err
      ),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "stalled",
                    "stalled banner must appear when last_error is set"
    assert_includes out, "connection refused",
                    "stalled banner must surface the error message for diagnosis"
  end

  def test_grid_mode_handles_nil_snapshot
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: nil, cols: 100),
      dispatch: @dispatch
    )
    out = @model.view
    refute_nil out, "nil snapshot must not crash compose_two_pane_view"
    assert out.is_a?(String)
  end

  # ---- v2 new-idea submission ----

  # Stub Hive::Tui::Subprocess.run_quiet! for the duration of a block.
  # Saves/restores the original via singleton-method swap so multiple
  # tests don't leak across each other when run in random order.
  def with_run_quiet_stub(stub_proc)
    sentinel = Hive::Tui::Subprocess.method(:run_quiet!)
    Hive::Tui::Subprocess.define_singleton_method(:run_quiet!, &stub_proc)
    yield
  ensure
    Hive::Tui::Subprocess.define_singleton_method(:run_quiet!, sentinel) if sentinel
  end

  def test_new_idea_submission_dispatches_hive_new_with_resolved_project
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 0, new_idea_buffer: "rss feeds"
      ),
      dispatch: @dispatch
    )
    captured_argv = nil
    with_run_quiet_stub(->(argv) { captured_argv = argv; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal [ "hive", "new", "hive", "rss feeds" ], captured_argv,
                 "submission must shell out to `hive new <project> <title>` " \
                 "(argv[0] is the executable; Open3.popen3 execs literally)"
    assert_equal :grid, @model.hive_model.mode, "successful submit must return to :grid"
    assert_equal "", @model.hive_model.new_idea_buffer
  end

  def test_new_idea_submission_with_empty_buffer_flashes_and_stays_in_new_idea
    # Plan §U6: empty/whitespace title flashes "title required" and
    # STAYS in :new_idea mode so the operator can keep typing without
    # re-opening via `n` after a fat-finger Enter. The buffer is
    # preserved (strip is validation-only) so any leading whitespace
    # the operator typed isn't lost.
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_buffer: "   "
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count, "empty/whitespace buffer must NOT spawn a subprocess"
    assert_equal :new_idea, @model.hive_model.mode,
                 "fat-finger Enter must NOT close the prompt"
    assert_equal "   ", @model.hive_model.new_idea_buffer,
                 "buffer is preserved so the operator's typing isn't lost"
    assert_match(/title required/, @model.hive_model.flash.to_s)
  end

  def test_new_idea_submission_with_unhealthy_project_flashes_specific_error
    # When `demo` is registered but its path is gone (a stale
    # registration after `rm -rf`), submit must NOT dispatch to a
    # doomed `bin/hive new` — the resulting subprocess would partially
    # write idea.md then fail at `git add` against the missing dir.
    # The flash must name the actual problem so the operator can
    # `hive deregister` or re-init.
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-04",
      "projects" => [
        { "name" => "demo", "error" => "missing_project_path", "tasks" => [] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 1, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count, "must NOT dispatch against a project with error: state"
    assert_match(/demo.*missing project path/, @model.hive_model.flash.to_s,
                 "flash must name the project AND the specific error")
  end

  def test_new_idea_submission_with_no_projects_flashes_and_does_not_dispatch
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01", "projects" => []
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count
    assert_match(/no projects/, @model.hive_model.flash.to_s)
  end

  # Regression for the rescue path in submit_new_idea. Errno::E2BIG
  # (oversized argv), ArgumentError (downstream model.with typo), or
  # Encoding::CompatibilityError (weird bytes) all bubble out of
  # run_quiet!. The rescue must flash a useful message AND preserve
  # the typed buffer + :new_idea mode so the operator can retry
  # without retyping — consistent with the empty-title UX, NOT the
  # validation-failure UX which clears the buffer.
  def test_new_idea_submission_rescues_subprocess_exception_and_preserves_buffer
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-04",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_buffer: "rss feeds"
      ),
      dispatch: @dispatch
    )
    with_run_quiet_stub(->(_argv) { raise Errno::E2BIG, "Argument list too long" }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal :new_idea, @model.hive_model.mode,
                 "rescue path must keep operator in :new_idea, not clobber to :grid"
    assert_equal "rss feeds", @model.hive_model.new_idea_buffer,
                 "rescue path must preserve typed buffer (don't make the user retype)"
    assert_match(/new failed.*E2BIG/, @model.hive_model.flash.to_s,
                 "flash must surface the actionable error class")
  end

  def test_new_idea_submission_subprocess_failure_surfaces_in_flash
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    with_run_quiet_stub(->(_argv) { [ 1, "", "boom: bad name\n" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_match(/new failed/, @model.hive_model.flash.to_s)
    assert_match(/boom: bad name/, @model.hive_model.flash.to_s)
    assert_equal :grid, @model.hive_model.mode, "failure still returns to :grid"
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

  def test_dispatch_command_routes_interactive_verbs_to_foreground_takeover
    # Override `verb_interactive?` on this BubbleModel INSTANCE so the
    # routing path is testable without hard-flagging a real verb in
    # `Hive::Workflows::VERBS` and without mutating module-level state
    # that other tests may read. Per-instance singleton method lives
    # only for the lifetime of @model.
    @model.define_singleton_method(:verb_interactive?) { |verb| verb.to_s == "develop" }

    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "slug", "--project", "demo", "--from", "3-plan" ],
      verb: "develop"
    )
    _, cmd = @model.update(msg)
    assert_kind_of Bubbletea::SequenceCommand, cmd,
      "interactive verbs route to takeover_command which returns a SequenceCommand " \
      "wrapping exit_alt → exec → enter_alt"
    classes = cmd.commands.map(&:class)
    assert_equal(
      [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
      classes
    )
  end

  def test_interactive_takeover_callable_runs_child_and_dispatches_subprocess_exited
    # Asserting the SequenceCommand shape is necessary but not
    # sufficient — the inner ExecCommand callable is what actually
    # spawns the child and dispatches SubprocessExited. Without
    # this test, swapping the callable for a no-op (or breaking
    # the dispatch invocation inside it) would silently pass.
    @model.define_singleton_method(:verb_interactive?) { |verb| verb.to_s == "develop" }
    captured = []
    @model.dispatch = ->(msg) { captured << msg }

    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "slug" ],
      verb: "develop"
    )
    _, cmd = @model.update(msg)
    exec_cmd = cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }
    refute_nil exec_cmd, "sequence must contain an ExecCommand"

    exec_cmd.callable.call

    assert_equal 1, captured.length,
      "callable must dispatch exactly one SubprocessExited (success path)"
    assert_kind_of Hive::Tui::Messages::SubprocessExited, captured.first
    assert_equal "develop", captured.first.verb
    assert_equal 0, captured.first.exit_code
  end

  def test_dispatch_command_routes_non_interactive_verbs_to_background_spawn
    # No verb is interactive by default, so the regular DispatchCommand
    # for "develop" must produce nil cmd (background spawn).
    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "slug" ],
      verb: "develop"
    )
    _, cmd = @model.update(msg)
    assert_nil cmd, "headless verbs go to dispatch_background; no Bubbletea Cmd returned"
  end

  def test_workflows_interactive_predicate_defaults_to_false
    require "hive/workflows"
    Hive::Workflows::VERBS.each_key do |verb|
      refute Hive::Workflows.interactive?(verb),
        "verb '#{verb}' must NOT be interactive by default — opt-in only when stdin is genuinely required"
    end
  end

  def test_workflows_interactive_predicate_returns_false_for_unknown_verb
    require "hive/workflows"
    refute Hive::Workflows.interactive?("nonexistent-verb")
  end

  def test_dispatch_command_flashes_running_message_for_immediate_feedback
    # Without the flash, pressing Enter on a `needs_input` row would
    # produce zero visual feedback because the spawn is asynchronous —
    # the user couldn't tell their keypress did anything. The flash is
    # overwritten by SubprocessExited's success/failure flash on
    # completion.
    #
    # argv[0] is `true` (exits 0, ignores all args) instead of "hive"
    # so the background spawn doesn't actually invoke the user's
    # production `hive` against their real config registry. The flash
    # text builder reads argv[1] / argv[2] (verb / slug) — those stay
    # unchanged so the regex assertion still works. Without this
    # guard, the test would leak `hive develop hello-world-test`
    # invocations into the operator's task store every time the
    # suite ran.
    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "hello-world-test", "--project", "demo", "--from", "3-plan" ],
      verb: "develop"
    )
    @model.update(msg)
    refute_nil @model.hive_model.flash, "dispatch must flash immediately so the user sees feedback"
    assert_match(/running.*hive develop.*hello-world-test/, @model.hive_model.flash,
      "flash must name the verb and slug the user dispatched on")
    refute_nil @model.hive_model.flash_set_at, "flash_set_at must stamp for TTL aging"
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

  def test_snapshot_with_multiple_kill_class_rows_triggers_heal_for_each
    captured = stub_heal_capture(@model)
    snap = snapshot_with([
      make_error_row(slug: "a", folder: "/x/.hive-state/stages/5-review/a", exit_code: 143),
      make_error_row(slug: "b", folder: "/x/.hive-state/stages/4-execute/b", exit_code: 137),
      make_error_row(slug: "c", folder: "/x/.hive-state/stages/3-plan/c", exit_code: 130)
    ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal(
      [ "/x/.hive-state/stages/3-plan/c",
        "/x/.hive-state/stages/4-execute/b",
        "/x/.hive-state/stages/5-review/a" ],
      captured.sort,
      "every kill-class row in the snapshot must trigger its own heal — not just the first"
    )
  end

  def test_snapshot_mixing_kill_class_and_real_failures_only_heals_kill_class
    captured = stub_heal_capture(@model)
    snap = snapshot_with([
      make_error_row(slug: "killed", folder: "/x/k", exit_code: 143),  # SIGTERM, heal
      make_error_row(slug: "failed", folder: "/x/f", exit_code: 1),    # real failure, skip
      make_error_row(slug: "timed",  folder: "/x/t", exit_code: nil, reason: "timeout") # skip
    ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/k" ], captured,
      "only kill-class signals heal; real failures and timeouts must reach the user untouched"
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

  # F11: the dedup cache used to be permanent; a folder that got
  # re-killed later in the session would never re-heal. Bound the
  # window so re-heals after HEAL_REPEAT_INTERVAL_SECONDS go through.
  def test_heal_cache_re_permits_after_interval_elapses
    captured = stub_heal_capture(@model)
    folder = "/x/.hive-state/stages/4-execute/killed"
    row = make_error_row(slug: "killed", folder: folder, exit_code: 143)
    snap = snapshot_with([ row ])

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length, "first kill-class error fires one heal"

    # Re-permit by backdating the cache entry past the interval.
    interval = Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS
    cache = @model.instance_variable_get(:@healed_folders)
    cache[folder] = Time.now - (interval + 1)

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 2, captured.length,
      "after HEAL_REPEAT_INTERVAL_SECONDS the slot must re-permit so a fresh kill on " \
      "the same folder/slug pair gets re-healed instead of stranded"
  end

  def test_heal_cache_keeps_blocking_within_interval_window
    captured = stub_heal_capture(@model)
    folder = "/x/.hive-state/stages/4-execute/killed"
    row = make_error_row(slug: "killed", folder: folder, exit_code: 143)
    snap = snapshot_with([ row ])

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length

    # Backdate by half the interval — still within the dedup window.
    interval = Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS
    cache = @model.instance_variable_get(:@healed_folders)
    cache[folder] = Time.now - (interval / 2.0)

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length,
      "within the interval window a repeated snapshot must NOT re-heal — that's the dedup contract"
  end

  def test_snapshot_arrived_still_updates_the_model_after_auto_heal
    stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "k", folder: "/x/y", exit_code: 143) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_same snap, @model.hive_model.snapshot,
      "auto-heal must not block the regular Update.apply path — the model still updates"
  end

  # F4: heal_marker passes --match-attr exit_code=<observed> so the
  # cross-process race window (auto-heal observes 143, concurrent
  # `hive run` writes 1, heal arrives) can't erase a real-failure
  # marker. Captures the actual argv handed to run_quiet!.
  def test_heal_marker_argv_includes_match_attr_for_observed_exit_code
    captured_argv = nil
    Hive::Tui::Subprocess.singleton_class.send(:alias_method, :__orig_run_quiet, :run_quiet!)
    Hive::Tui::Subprocess.define_singleton_method(:run_quiet!) do |argv|
      captured_argv = argv
      [ 0, "", "" ]
    end

    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/4-execute/killed", exit_code: 143)
    @model.send(:heal_marker, row)

    assert_equal [
      "hive", "markers", "clear",
      "/x/.hive-state/stages/4-execute/killed",
      "--name", "ERROR",
      "--match-attr", "exit_code=143"
    ], captured_argv,
      "heal_marker must scope the clear to the kill-class exit_code we observed"
  ensure
    Hive::Tui::Subprocess.singleton_class.send(:alias_method, :run_quiet!, :__orig_run_quiet)
    Hive::Tui::Subprocess.singleton_class.send(:remove_method, :__orig_run_quiet)
  end

  # ---- SubprocessExited diagnostic interception ----
  #
  # Pattern-matches the captured stderr in SUBPROCESS_LOG_PATH for
  # known setup-class errors and replaces the generic "exited N —
  # tail …" flash with an actionable message. Dogfood-driven:
  # `hive pr` exit 1 looped on a demo project that had no `origin`
  # remote — the user wanted "project is not set up" surfaced
  # directly so they could go fix the repo without `tail`-ing the log.

  def with_isolated_subprocess_log
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "hive-tui-subprocess.log")
      original = Hive::Tui::Subprocess::SUBPROCESS_LOG_PATH
      Hive::Tui::Subprocess.send(:remove_const, :SUBPROCESS_LOG_PATH)
      Hive::Tui::Subprocess.const_set(:SUBPROCESS_LOG_PATH, log_path)
      begin
        yield log_path
      ensure
        Hive::Tui::Subprocess.send(:remove_const, :SUBPROCESS_LOG_PATH)
        Hive::Tui::Subprocess.const_set(:SUBPROCESS_LOG_PATH, original)
      end
    end
  end

  def write_log_section(log_path, argv:, stderr:, exit_code:)
    File.open(log_path, "a") do |f|
      f.puts "----- 2026-04-28T11:05:47Z BEGIN: #{argv.join(' ')} -----"
      f.puts stderr
      f.puts "----- 2026-04-28T11:05:48Z END exit=#{exit_code}: #{argv.join(' ')} -----"
    end
  end

  def test_missing_origin_remote_shows_project_not_set_up
    with_isolated_subprocess_log do |log_path|
      write_log_section(
        log_path,
        argv: %w[hive pr hello-world-test-260425-431f --project demo --from 6-pr],
        stderr: "hive: git push failed: fatal: 'origin' does not appear to be a git repository",
        exit_code: 1
      )

      @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 1))

      flash = @model.hive_model.flash
      refute_nil flash
      assert_match(/demo:/, flash, "diagnostic must name the project so the user knows which repo to fix")
      assert_match(/project not set up/i, flash,
        "user wanted 'project is not set up' surfaced directly so they can go create the repo manually")
      refute_match(/tail/, flash, "diagnostic supersedes the generic 'tail the log' hint")
    end
  end

  def test_unknown_failure_falls_back_to_default_flash
    with_isolated_subprocess_log do |log_path|
      write_log_section(
        log_path,
        argv: %w[hive develop slug --project p --from 3-plan],
        stderr: "some unknown error nobody patterns against",
        exit_code: 1
      )

      @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "develop", exit_code: 1))

      # No specific diagnostic → Update.apply's default "exited N — tail …" flash applies.
      flash = @model.hive_model.flash
      assert_match(/exited 1/, flash, "unrecognized failures fall back to the generic exit-code flash")
      assert_match(/tail/, flash, "fall-back flash includes the log-path hint")
    end
  end

  def test_zero_exit_does_not_flash_diagnostic
    @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 0))
    assert_nil @model.hive_model.flash, "zero exit must not flash anything (success path is silent)"
  end

  # Last-resort safety net: an unhandled exception escaping
  # `BubbleModel#update` would unwind out of Bubbletea's runner and
  # tear down the alt-screen mid-frame. Pin that ANY StandardError
  # is converted into a flash + the TUI keeps running.
  def test_unhandled_exception_in_update_becomes_flash_not_crash
    # The safety net at `BubbleModel#update`'s rescue catches
    # exceptions NOT covered by per-handler rescues. Force a
    # genuinely unanticipated exception by overriding `translate`
    # on this BubbleModel INSTANCE — `translate` is the first thing
    # `update` calls before any per-handler rescue could catch, so
    # raising here exercises the top-level safety net. Per-instance
    # singleton method, no module-level mutation.
    @model.define_singleton_method(:translate) do |_msg|
      raise "synthetic unanticipated failure for the safety-net test"
    end
    _, cmd = @model.update(Hive::Tui::Messages::WindowSized.new(cols: 80, rows: 24))
    assert_nil cmd, "safety net returns nil cmd; never propagates exception"
    refute_nil @model.hive_model.flash, "exception must surface as a flash"
    assert_match(/internal error/i, @model.hive_model.flash,
      "flash must label this as the safety-net catchall, not a per-handler diagnostic")
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

  # F3: Tail#poll! was never called — the view was frozen at the
  # bytes read by Tail#open!. open_log_tail now schedules a recurring
  # LOG_TAIL_POLL tick; the handler calls tail.poll! and reschedules
  # while mode is still :log_tail.
  def test_open_log_tail_returns_log_tail_poll_tick_cmd
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "tail-260428-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "5-review", slug)
      logs = File.join(task_folder, "logs")
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "agent.log"), "first line\n")

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "5-review", slug: slug,
        folder: task_folder, state_file: nil, marker: nil, attrs: nil,
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "agent_running", action_label: "Agent running", suggested_command: nil
      )

      _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: row))
      assert_kind_of Bubbletea::TickCommand, cmd,
        "successful open_log_tail must seed the LOG_TAIL_POLL tick so new bytes drain"
      assert_equal :log_tail, @model.hive_model.mode
    end
  end

  def test_log_tail_poll_drains_new_bytes_and_reschedules
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.log")
      File.write(log_path, "first line\n")
      tail = Hive::Tui::LogTail::Tail.new(log_path)
      tail.open!
      wrapper = Hive::Tui::BubbleModel::LogTailContext.new(tail: tail, claude_pid_alive: true)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :log_tail, tail_state: wrapper),
        dispatch: @dispatch
      )

      # Append bytes after open!; tail's view is frozen until poll!
      File.write(log_path, "second line\n", mode: "a")
      assert_equal [ "first line" ], tail.lines(50),
        "without poll! the new bytes must not yet be visible — proves the regression existed"

      _, cmd = @model.update(Hive::Tui::Messages::LOG_TAIL_POLL)
      assert_includes tail.lines(50), "second line",
        "LOG_TAIL_POLL must drain new bytes via tail.poll!"
      assert_kind_of Bubbletea::TickCommand, cmd,
        "must reschedule a fresh tick while the user is still in :log_tail mode"
    end
  end

  def test_log_tail_poll_stops_rescheduling_after_mode_change_out
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, tail_state: nil),
      dispatch: @dispatch
    )
    _, cmd = @model.update(Hive::Tui::Messages::LOG_TAIL_POLL)
    assert_nil cmd,
      "LOG_TAIL_POLL must not reschedule after the user has left :log_tail mode"
  end

  # F6: every open_log_tail allocates a File handle inside Tail#open!.
  # apply_back was clearing tail_state but never calling tail.close!,
  # so each open/dismiss cycle leaked one FD until the process hit
  # ENFILE/EMFILE.
  def test_back_from_log_tail_closes_underlying_file_descriptor
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.log")
      File.write(log_path, "first line\n")
      tail = Hive::Tui::LogTail::Tail.new(log_path)
      tail.open!
      file = tail.instance_variable_get(:@file)
      refute file.closed?, "fixture sanity: Tail#open! must leave the underlying File open"

      wrapper = Hive::Tui::BubbleModel::LogTailContext.new(tail: tail, claude_pid_alive: true)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :log_tail, tail_state: wrapper),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::BACK)
      assert file.closed?,
        "BACK in :log_tail mode must close the underlying File or every open/dismiss leaks one FD"
      assert_equal :grid, @model.hive_model.mode
      assert_nil @model.hive_model.tail_state,
        "Update.apply_back still owns clearing tail_state — F6 only adds the close! side effect"
    end
  end

  def test_back_from_other_modes_does_not_attempt_tail_close
    # Defensive: the close hook must not fire when mode != :log_tail
    # (no tail_state to close). Otherwise a stale wrapper from a
    # different code path could be touched on every grid-mode Esc.
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )
    # No exception means the guard works.
    @model.update(Hive::Tui::Messages::BACK)
    assert_equal :grid, @model.hive_model.mode
  end

  # F8: heal Threads must be tracked so App.run_charm's ensure block
  # can reap them at TUI exit. Pre-F8 the threads were unreferenced
  # after spawn — quitting mid-flight left zombies whose dispatch
  # eventually crashed against a dead runner.
  def test_kill_inflight_heals_joins_or_kills_in_flight_threads
    # Stub heal_marker with a slow stand-in so we can observe the
    # join-then-kill behavior under a deterministic deadline.
    @model.define_singleton_method(:heal_marker) do |_row|
      sleep 5 # well past JOIN_TIMEOUT_SECONDS
    end

    rows = 3.times.map { |i| make_error_row(slug: "k#{i}", folder: "/x/k#{i}", exit_code: 143) }
    threads = rows.map { |r| @model.send(:spawn_heal_thread, r) }
    assert_equal 3, threads.size
    threads.each { |t| assert t.alive?, "fixture sanity: stub thread should still be alive" }

    started = Time.now
    @model.kill_inflight_heals!
    elapsed = Time.now - started

    threads.each do |t|
      refute t.alive?, "kill_inflight_heals! must reap every tracked Thread"
    end
    assert elapsed < Hive::Tui::BubbleModel::JOIN_TIMEOUT_SECONDS + 1.0,
      "kill must respect the join timeout — got #{elapsed}s; deadline is " \
      "JOIN_TIMEOUT_SECONDS (#{Hive::Tui::BubbleModel::JOIN_TIMEOUT_SECONDS}s) plus a small buffer"
  end

  def test_spawn_heal_thread_self_prunes_when_heal_completes
    @model.define_singleton_method(:heal_marker) { |_row| nil }
    row = make_error_row(slug: "fast", folder: "/x/fast", exit_code: 143)
    t = @model.send(:spawn_heal_thread, row)
    t.join(2)

    tracked = @model.instance_variable_get(:@heal_threads)
    refute_includes tracked, t,
      "completed heal Thread must remove itself from @heal_threads to bound the list under long sessions"
  end

  def test_kill_inflight_heals_is_safe_when_no_threads_tracked
    # Common shape: TUI quits before any kill-class error arrived.
    @model.kill_inflight_heals!
    # Must not raise; nothing to assert beyond the absence of exception.
  end
end
