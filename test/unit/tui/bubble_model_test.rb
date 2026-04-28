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

  def test_snapshot_arrived_still_updates_the_model_after_auto_heal
    stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "k", folder: "/x/y", exit_code: 143) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_same snap, @model.hive_model.snapshot,
      "auto-heal must not block the regular Update.apply path — the model still updates"
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
end
