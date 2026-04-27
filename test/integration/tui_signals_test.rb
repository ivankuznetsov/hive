require "test_helper"
require "hive/tui/subprocess_registry"

# Pins the SubprocessRegistry invariants the SIGHUP cleanup hook in
# `Hive::Tui::App.run_charm` depends on: `kill_inflight!` must never
# raise even when the registry is empty or holds the `:placeholder`
# sentinel, because the trap fires from arbitrary signal-handler
# context where exceptions would tear down the parent process.
#
# Pre-U11 this file also tested `Hive::Tui.install_terminal_safety_hooks`
# (curses backend's at_exit + SIGHUP wiring). U11 deleted the curses
# path; the SIGHUP trap now lives in `App.run_charm` and is exercised
# end-to-end by the PTY smoke tests.
class TuiSignalsTest < Minitest::Test
  include HiveTestHelper

  def setup
    Hive::Tui::SubprocessRegistry.clear
  end

  def test_subprocess_registry_kill_inflight_is_safe_when_empty
    Hive::Tui::SubprocessRegistry.clear
    Hive::Tui::SubprocessRegistry.kill_inflight! # must not raise
  end

  def test_subprocess_registry_kill_inflight_is_safe_with_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    Hive::Tui::SubprocessRegistry.kill_inflight! # placeholder → no-op + clear
    assert_nil Hive::Tui::SubprocessRegistry.current,
               "kill_inflight! must clear the slot after handling placeholder"
  end
end
