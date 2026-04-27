require "test_helper"
require "hive/tui"
require "hive/tui/subprocess_registry"

# U9 — terminal-hostility hooks.
#
# `Hive::Tui.run` installs an `at_exit` cleanup AND a SIGHUP trap that
# flips a `terminate_requested` flag the render loop checks between
# frames. Both have to land BEFORE the first `Curses.init_screen` so a
# crash during init still restores the terminal.
#
# The full PTY-driven exit-on-SIGHUP scenario is covered by the U11
# smoke test (which spawns `bin/hive tui`); here we pin the hooks'
# *installation* and the cooperative-cancellation flag without entering
# curses (the test runner has no tty).
class TuiSignalsTest < Minitest::Test
  include HiveTestHelper

  def setup
    # Reset the install-once guard so each test exercises a fresh hook
    # install. This also lets us verify the `?` hooks_installed flag
    # transitions exactly once even across repeated `run` invocations.
    Hive::Tui.instance_variable_set(:@hooks_installed, false)
    Hive::Tui.instance_variable_set(:@terminate_requested, false)
    Hive::Tui::SubprocessRegistry.clear
  end

  def teardown
    # Restore SIGHUP to a sane default so we don't leak the test trap
    # into the next test or into the rake harness itself.
    Signal.trap("HUP", "DEFAULT")
    Hive::Tui.instance_variable_set(:@hooks_installed, false)
    Hive::Tui.instance_variable_set(:@terminate_requested, false)
  end

  def test_install_terminal_safety_hooks_is_idempotent
    Hive::Tui.send(:install_terminal_safety_hooks)
    assert Hive::Tui.atexit_registered?, "hooks should be flagged installed after first call"

    # Second call must not stack callbacks. We can't easily count
    # at_exit callbacks, but we can assert the flag stays true and no
    # exception fires on a re-install.
    Hive::Tui.send(:install_terminal_safety_hooks)
    assert Hive::Tui.atexit_registered?
  end

  def test_sighup_trap_flips_terminate_requested_flag
    Hive::Tui.send(:install_terminal_safety_hooks)
    refute Hive::Tui.terminate_requested?, "fresh install starts un-terminated"

    Process.kill("HUP", Process.pid)
    # Trap delivery is synchronous in MRI for self-signals after the
    # next interpreter checkpoint; a tight loop with a wait-for-condition
    # is the no-fixed-sleep way to wait for it.
    waited = wait_for_condition(deadline_seconds: 1.0) { Hive::Tui.terminate_requested? }
    assert waited, "SIGHUP should flip terminate_requested? within 1s"
  end

  def test_request_terminate_bang_sets_flag_without_signal
    Hive::Tui.send(:install_terminal_safety_hooks)
    Hive::Tui.request_terminate!
    assert Hive::Tui.terminate_requested?, "request_terminate! is the test seam for the trap path"
  end

  def test_subprocess_registry_kill_inflight_is_safe_when_empty
    # Kept in this test file because it pins the at_exit hook's
    # invariant: even with an empty registry, kill_inflight! must
    # never raise (it's the trap target).
    Hive::Tui::SubprocessRegistry.clear
    Hive::Tui::SubprocessRegistry.kill_inflight! # must not raise
  end

  def test_subprocess_registry_kill_inflight_is_safe_with_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    Hive::Tui::SubprocessRegistry.kill_inflight! # placeholder → no-op + clear
    assert_nil Hive::Tui::SubprocessRegistry.current,
               "kill_inflight! must clear the slot after handling placeholder"
  end

  private

  def wait_for_condition(deadline_seconds:, interval: 0.02)
    deadline = Time.now + deadline_seconds
    loop do
      return true if yield
      return false if Time.now > deadline

      sleep interval
    end
  end
end
