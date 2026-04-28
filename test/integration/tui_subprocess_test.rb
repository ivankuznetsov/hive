require "test_helper"
require "hive/tui/subprocess"
require "hive/tui/subprocess_registry"

# Integration tests for `Hive::Tui::Subprocess.takeover_command(...)`,
# `Subprocess.run_quiet!`, and `SubprocessRegistry`. These exercise
# real `Process.spawn` / `Open3.capture3` against a small bash
# fixture so we cover the actual fork-exec, pgid lookup, wait, and
# trap save/restore paths the TUI relies on at runtime.
#
# Pre-U11 this file also tested `Subprocess.takeover!` (curses
# backend's full-screen takeover). U11 deleted the curses path;
# `takeover_command` now wraps the same spawn-and-wait core for
# the Bubble Tea runner.
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

  # ---- run_quiet! ----

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

  def test_registry_cleared_after_run_quiet
    Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry should be cleared after run_quiet! returns"
  end

  def test_run_quiet_returns_command_not_found_sentinel_when_binary_missing
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ "/path/that/does/not/exist/hive-fake" ])
    assert_equal 127, exit_status
    assert_equal "", out
    assert_match(%r{command not found: /path/that/does/not/exist/hive-fake}, err)
  end

  # ---- SubprocessRegistry contract ----

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

  def test_registry_register_overwrites_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    assert_equal :placeholder, Hive::Tui::SubprocessRegistry.current
    Hive::Tui::SubprocessRegistry.register(12_345)
    assert_equal 12_345, Hive::Tui::SubprocessRegistry.current
  ensure
    Hive::Tui::SubprocessRegistry.clear
  end
end

# `Subprocess.takeover_command(argv, dispatch:) → Bubbletea::ExecCommand`.
# The framework owns suspend/resume of raw mode + cursor + input reader
# (`Bubbletea::Runner#exec_process`), so this layer only needs to spawn
# the child with pgroup forwarding, wait, and dispatch a SubprocessExited
# message back into the loop. The `dispatch:` lambda is the seam — App.run_charm
# wires `dispatch: runner.method(:send)` in U10; tests pass a capture lambda.
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
  #
  # Helper: extract the inner ExecCommand from the sequence. The
  # outer SequenceCommand wraps three commands: exit_alt_screen, the
  # exec, and enter_alt_screen — see `Subprocess.takeover_command`'s
  # rationale for the alt-screen toggle.
  def exec_inside(sequence)
    assert_kind_of Bubbletea::SequenceCommand, sequence,
      "takeover_command returns a sequence wrapping exit_alt → exec → enter_alt"
    inner = sequence.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }
    refute_nil inner, "sequence must contain an ExecCommand for the spawn"
    inner
  end

  def test_takeover_command_returns_alt_screen_wrapped_exec
    cmd = Hive::Tui::Subprocess.takeover_command([ "hive", "develop", "slug" ], dispatch: @dispatch)
    assert_kind_of Bubbletea::SequenceCommand, cmd,
      "takeover_command returns a sequence so alt-screen toggles around the exec"
    classes = cmd.commands.map(&:class)
    assert_equal(
      [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
      classes,
      "sequence order must be exit_alt → exec → enter_alt so the child writes " \
      "to the main screen and the alt-screen redraws cleanly on return"
    )
    inner = exec_inside(cmd)
    assert_respond_to inner.callable, :call, "ExecCommand#callable must be invokable"
  end

  def test_takeover_command_does_not_spawn_at_construction_time
    initial_messages = @messages.dup
    Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD ], dispatch: @dispatch)
    assert_equal initial_messages, @messages,
      "takeover_command must defer spawn to callable invocation; no message before .call"
  end

  # ---- Callable execution ----

  def test_callable_dispatches_subprocess_exited_with_zero_on_clean_exit
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "pr" ], dispatch: @dispatch))
    cmd.callable.call

    assert_equal 1, @messages.length, "exactly one SubprocessExited per execution"
    msg = @messages.first
    assert_kind_of Hive::Tui::Messages::SubprocessExited, msg
    assert_equal "pr", msg.verb, "verb must be argv[1] cached at construction time"
    assert_equal 0, msg.exit_code
  end

  def test_callable_dispatches_nonzero_exit_code
    ENV["HIVE_TUI_FAKE_EXIT"] = "7"
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "develop" ], dispatch: @dispatch))
    cmd.callable.call

    msg = @messages.first
    assert_equal 7, msg.exit_code
    assert_equal "develop", msg.verb
  end

  def test_callable_dispatches_command_not_found_when_binary_missing
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command(
      [ "/path/that/does/not/exist/hive-fake", "develop" ],
      dispatch: @dispatch
    ))
    cmd.callable.call

    msg = @messages.first
    assert_equal 127, msg.exit_code,
      "ENOENT must translate to 127 (POSIX command-not-found) so the existing flash path handles it"
    assert_equal "develop", msg.verb
  end

  def test_callable_dispatches_signal_exit_on_pgroup_term
    ENV["HIVE_TUI_FAKE_BLOCK"] = "1"
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "review" ], dispatch: @dispatch))

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
      cmd = exec_inside(Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "pr" ], dispatch: @dispatch))
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
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command([ FAKE_CHILD, "pr" ], dispatch: @dispatch))
    cmd.callable.call
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry must be cleared after callable so SIGHUP doesn't kill nothing"
  end

  def test_callable_clears_registry_on_missing_binary
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command(
      [ "/no/such/binary", "develop" ],
      dispatch: @dispatch
    ))
    cmd.callable.call
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "registry must be cleared even when spawn raises ENOENT"
  end

  # ---- Verb caching from argv[1] ----

  def test_verb_cached_from_argv_index_one
    cmd = exec_inside(Hive::Tui::Subprocess.takeover_command(
      [ FAKE_CHILD, "brainstorm", "some-slug", "--from", "1-input" ],
      dispatch: @dispatch
    ))
    cmd.callable.call
    assert_equal "brainstorm", @messages.first.verb
  end
end
