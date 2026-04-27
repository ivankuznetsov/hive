require "test_helper"
require "hive/tui/subprocess"
require "hive/tui/subprocess_registry"

# Integration tests for U4 — Subprocess.takeover!, Subprocess.run_quiet!, and
# SubprocessRegistry. These exercise real `Process.spawn` / `Open3.capture3`
# against a small bash fixture so we cover the actual fork-exec, pgid lookup,
# wait, and trap save/restore paths the TUI relies on at runtime.
#
# Curses is NOT initialised here — the implementation must detect that
# `defined?(Curses)` is nil and skip the curses-state save/restore steps.
#
# Gaps (intentionally not covered, see plan U4 §"Test scenarios"):
#   * SIGSEGV / tcsetattr-still-runs — the plan flagged this as hard to wire
#     reliably across CI environments; the `ensure` block restores termios
#     unconditionally so the same code path runs on normal exit.
#   * Parent's installed INT trap forwarding the signal to -pgid — directly
#     testing this would either require killing the test process itself or
#     an IO.popen wrapper. We cover the structurally similar TERM path: send
#     SIGTERM to the child's pgid from a thread, observe takeover! returns
#     a signal-shaped exit. The trap save/restore is verified separately via
#     the trap-restoration assertion.
class TuiSubprocessTest < Minitest::Test
  include HiveTestHelper

  FAKE_CHILD = File.expand_path("fixtures/tui-fake-child", __dir__).freeze

  def setup
    # Defensive: any previous test that crashed mid-flight could leave the
    # registry populated. Re-zeroing it keeps tests order-independent.
    Hive::Tui::SubprocessRegistry.clear
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
  end

  def teardown
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
    Hive::Tui::SubprocessRegistry.clear
  end

  def test_fixture_is_executable
    assert File.executable?(FAKE_CHILD), "fake child fixture must be executable"
  end

  def test_takeover_returns_zero_on_clean_exit
    status = Hive::Tui::Subprocess.takeover!([ FAKE_CHILD ])
    assert_equal 0, status
  end

  def test_takeover_returns_nonzero_exit_status
    ENV["HIVE_TUI_FAKE_EXIT"] = "7"
    status = Hive::Tui::Subprocess.takeover!([ FAKE_CHILD ])
    assert_equal 7, status
  end

  def test_run_quiet_captures_stdout
    ENV["HIVE_TUI_FAKE_STDOUT"] = "hello-tui"
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_equal 0, exit_status
    assert_equal "hello-tui", out
    assert_equal "", err
  end

  def test_run_quiet_captures_stderr_and_nonzero_status
    ENV["HIVE_TUI_FAKE_STDERR"] = "boom"
    ENV["HIVE_TUI_FAKE_EXIT"] = "3"
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_equal 3, exit_status
    assert_equal "", out
    assert_equal "boom", err
  end

  def test_takeover_returns_signal_exit_when_child_killed_via_pgid
    # See header comment — this exercises the structurally-equivalent TERM path
    # rather than the parent-trap-forwarding-INT path which would need IO.popen.
    ENV["HIVE_TUI_FAKE_BLOCK"] = "1"
    killer = Thread.new do
      # Poll for the registry to hold a real pgid (not :placeholder), then term it.
      30.times do
        pgid = Hive::Tui::SubprocessRegistry.current
        if pgid.is_a?(Integer)
          begin
            Process.kill("TERM", -pgid)
          rescue Errno::ESRCH
            nil
          end
          break
        end
        sleep 0.02
      end
    end
    status = Hive::Tui::Subprocess.takeover!([ FAKE_CHILD ])
    killer.join
    # `status.exitstatus || 128 + termsig` — TERM is signal 15, so 143.
    assert_equal 128 + Signal.list.fetch("TERM"), status,
      "takeover! should report 128+SIGTERM for a SIGTERM-killed child"
  end

  def test_takeover_restores_int_and_term_traps
    before_int = trap("INT", "DEFAULT")
    before_term = trap("TERM", "DEFAULT")
    begin
      Hive::Tui::Subprocess.takeover!([ FAKE_CHILD ])
      after_int = trap("INT", "DEFAULT")
      after_term = trap("TERM", "DEFAULT")
      assert_equal "DEFAULT", after_int, "INT trap should be restored after takeover!"
      assert_equal "DEFAULT", after_term, "TERM trap should be restored after takeover!"
    ensure
      trap("INT", before_int)
      trap("TERM", before_term)
    end
  end

  def test_run_quiet_restores_int_and_term_traps
    before_int = trap("INT", "DEFAULT")
    before_term = trap("TERM", "DEFAULT")
    begin
      Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
      after_int = trap("INT", "DEFAULT")
      after_term = trap("TERM", "DEFAULT")
      assert_equal "DEFAULT", after_int, "INT trap should be restored after run_quiet!"
      assert_equal "DEFAULT", after_term, "TERM trap should be restored after run_quiet!"
    ensure
      trap("INT", before_int)
      trap("TERM", before_term)
    end
  end

  def test_registry_holds_pgid_during_takeover
    # Coarser check (per plan): the registry observably holds a non-nil value
    # at some point during the child's life and is nil after takeover! returns.
    ENV["HIVE_TUI_FAKE_BLOCK"] = "1"
    observed = []
    poll_thread = Thread.new do
      80.times do
        observed << Hive::Tui::SubprocessRegistry.current
        sleep 0.005
      end
    end
    killer = Thread.new do
      30.times do
        pgid = Hive::Tui::SubprocessRegistry.current
        if pgid.is_a?(Integer)
          begin
            Process.kill("TERM", -pgid)
          rescue Errno::ESRCH
            nil
          end
          break
        end
        sleep 0.02
      end
    end
    Hive::Tui::Subprocess.takeover!([ FAKE_CHILD ])
    killer.join
    poll_thread.join
    assert observed.any? { |v| v.is_a?(Integer) },
      "registry should hold an Integer pgid during the child's life: observed=#{observed.inspect}"
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry should be cleared after takeover! returns"
  end

  def test_registry_cleared_after_run_quiet
    Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry should be cleared after run_quiet! returns"
  end

  def test_registry_kill_inflight_is_noop_when_empty
    Hive::Tui::SubprocessRegistry.clear
    assert_nil Hive::Tui::SubprocessRegistry.kill_inflight!,
      "kill_inflight! on empty registry should be a no-op returning nil"
  end

  def test_registry_kill_inflight_is_noop_for_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    assert_nil Hive::Tui::SubprocessRegistry.kill_inflight!,
      "kill_inflight! on :placeholder should not raise and should clear"
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "kill_inflight! should clear the slot even when placeholder"
  end

  # `Process.spawn` with a missing binary used to propagate Errno::ENOENT
  # straight into the TUI render loop and tear the screen down. The
  # subprocess seam now translates ENOENT/EACCES into the POSIX-shell
  # 127 ("command not found") sentinel so the caller's existing
  # non-zero-status flash path handles it.
  def test_takeover_returns_command_not_found_sentinel_when_binary_missing
    status = Hive::Tui::Subprocess.takeover!([ "/path/that/does/not/exist/hive-fake" ])
    assert_equal 127, status,
                 "takeover! must translate Errno::ENOENT to 127 instead of raising"
  end

  def test_run_quiet_returns_command_not_found_sentinel_when_binary_missing
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ "/path/that/does/not/exist/hive-fake" ])
    assert_equal 127, exit_status
    assert_equal "", out
    assert_match(%r{command not found: /path/that/does/not/exist/hive-fake}, err)
  end

  def test_registry_register_overwrites_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    assert_equal :placeholder, Hive::Tui::SubprocessRegistry.current
    Hive::Tui::SubprocessRegistry.register(12_345)
    assert_equal 12_345, Hive::Tui::SubprocessRegistry.current
  ensure
    Hive::Tui::SubprocessRegistry.clear
  end
end

# U6 — `Subprocess.takeover_command(argv, dispatch:) → Bubbletea::ExecCommand`.
# The framework owns suspend/resume of raw mode + cursor + input reader
# (Bubbletea::Runner#exec_process), so this layer only needs to spawn the
# child with pgroup forwarding, wait, and dispatch a SubprocessExited
# message back into the loop. The `dispatch:` lambda is the seam — App.run_charm
# wires `dispatch: runner.method(:send)` in U10; tests pass a capture lambda.
#
# We do NOT call `Bubbletea.exec`'s built-in `message:` arg because the exit
# code isn't known at construction time. Closure-capture inside the callable
# is the only path that lets us send the actual exit code back.
class TuiSubprocessTakeoverCommandTest < Minitest::Test
  include HiveTestHelper

  FAKE_CHILD = TuiSubprocessTest::FAKE_CHILD

  def setup
    Hive::Tui::SubprocessRegistry.clear
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
    @messages = []
    @dispatch = ->(msg) { @messages << msg }
  end

  def teardown
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
    Hive::Tui::SubprocessRegistry.clear
  end

  # ---- Builder shape ----

  def test_takeover_command_returns_bubbletea_exec_command
    cmd = Hive::Tui::Subprocess.takeover_command([ "hive", "develop", "slug" ], dispatch: @dispatch)
    assert_kind_of Bubbletea::ExecCommand, cmd,
      "takeover_command must return a Bubbletea::ExecCommand the runner knows how to execute"
    assert_respond_to cmd.callable, :call,
      "ExecCommand#callable must be invokable by the runner"
  end

  def test_takeover_command_does_not_spawn_at_construction_time
    # Constructing the Cmd must not fork a child — the child only runs when
    # the runner calls callable.call() inside its suspend window. A pre-spawn
    # would race with the framework's raw-mode disable.
    initial_messages = @messages.dup
    Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD ], dispatch: @dispatch)
    assert_equal initial_messages, @messages,
      "takeover_command must defer spawn to callable invocation; no message before .call"
  end

  # ---- Callable execution ----

  def test_callable_dispatches_subprocess_exited_with_zero_on_clean_exit
    cmd = Hive::Tui::Subprocess.takeover_command([ "hive", "pr", "slug" ], dispatch: @dispatch)
    # Patch argv[0] to the actual fake-child path while preserving the verb
    # at argv[1] for caching. (Real call site already produces real `hive`
    # argv; here we just want to drive the spawn against the fixture.)
    cmd = Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
    cmd.callable.call

    assert_equal 1, @messages.length, "exactly one SubprocessExited per execution"
    msg = @messages.first
    assert_kind_of Hive::Tui::Messages::SubprocessExited, msg
    assert_equal "pr", msg.verb, "verb must be argv[1] cached at construction time"
    assert_equal 0, msg.exit_code
  end

  def test_callable_dispatches_nonzero_exit_code
    ENV["HIVE_TUI_FAKE_EXIT"] = "7"
    cmd = Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "develop" ], dispatch: @dispatch)
    cmd.callable.call

    msg = @messages.first
    assert_equal 7, msg.exit_code
    assert_equal "develop", msg.verb
  end

  def test_callable_dispatches_command_not_found_when_binary_missing
    cmd = Hive::Tui::Subprocess.takeover_command(
      [ "/path/that/does/not/exist/hive-fake", "develop" ],
      dispatch: @dispatch
    )
    cmd.callable.call

    msg = @messages.first
    assert_equal 127, msg.exit_code,
      "ENOENT must translate to 127 (POSIX command-not-found) so the existing flash path handles it"
    assert_equal "develop", msg.verb
  end

  def test_callable_dispatches_signal_exit_on_pgroup_term
    ENV["HIVE_TUI_FAKE_BLOCK"] = "1"
    cmd = Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "review" ], dispatch: @dispatch)

    killer = Thread.new do
      30.times do
        pgid = Hive::Tui::SubprocessRegistry.current
        if pgid.is_a?(Integer)
          begin
            Process.kill("TERM", -pgid)
          rescue Errno::ESRCH
            nil
          end
          break
        end
        sleep 0.02
      end
    end
    cmd.callable.call
    killer.join

    msg = @messages.first
    assert_equal 128 + Signal.list.fetch("TERM"), msg.exit_code,
      "SIGTERM-killed child must report 128+SIGTERM (143) per POSIX shell convention"
    assert_equal "review", msg.verb
  end

  # ---- Trap and registry hygiene ----

  def test_callable_restores_int_and_term_traps
    before_int = trap("INT", "DEFAULT")
    before_term = trap("TERM", "DEFAULT")
    begin
      cmd = Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
      cmd.callable.call
      after_int = trap("INT", "DEFAULT")
      after_term = trap("TERM", "DEFAULT")
      assert_equal "DEFAULT", after_int, "INT trap restored after callable returns"
      assert_equal "DEFAULT", after_term, "TERM trap restored after callable returns"
    ensure
      trap("INT", before_int)
      trap("TERM", before_term)
    end
  end

  def test_callable_clears_registry_on_clean_exit
    cmd = Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
    cmd.callable.call
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry must be cleared after callable so SIGHUP doesn't kill nothing"
  end

  def test_callable_clears_registry_on_missing_binary
    cmd = Hive::Tui::Subprocess.takeover_command(
      [ "/no/such/binary", "develop" ],
      dispatch: @dispatch
    )
    cmd.callable.call
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry must be cleared even when spawn raises ENOENT"
  end

  # ---- Verb caching from argv[1] ----

  def test_verb_cached_from_argv_index_one
    # Synthetic: argv[0] is the binary, argv[1] is the verb. Cache at construction
    # time so SubprocessExited carries the verb name even when argv leaks past us.
    cmd = Hive::Tui::Subprocess.takeover_command(
      [ FAKE_CHILD, "brainstorm", "some-slug", "--from", "1-input" ],
      dispatch: @dispatch
    )
    cmd.callable.call
    assert_equal "brainstorm", @messages.first.verb
  end
end
