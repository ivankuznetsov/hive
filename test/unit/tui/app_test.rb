require "test_helper"
require "hive/tui/app"

# `Hive::Tui::App` is the backend dispatcher introduced by U1 of the
# Charm migration plan (docs/plans/2026-04-27-003-refactor-hive-tui-
# charm-bubbletea-plan.md). It routes between the legacy curses run
# loop and the new charm/bubbletea path based on `HIVE_TUI_BACKEND`.
# These tests pin the env-var contract — the actual backend behavior
# is exercised by other suites (curses: existing test/integration/tui_*;
# charm: future tests landed alongside U3+).
class TuiAppTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_backend = ENV["HIVE_TUI_BACKEND"]
  end

  def teardown
    if @prev_backend
      ENV["HIVE_TUI_BACKEND"] = @prev_backend
    else
      ENV.delete("HIVE_TUI_BACKEND")
    end
  end

  def test_backend_defaults_to_charm_when_env_unset
    # U10 flipped the default from curses to charm. Curses remains
    # accessible as `HIVE_TUI_BACKEND=curses` until U11 deletes the
    # legacy code path entirely.
    ENV.delete("HIVE_TUI_BACKEND")
    assert_equal Hive::Tui::App::CHARM, Hive::Tui::App.backend
  end

  def test_backend_returns_curses_when_env_explicit
    ENV["HIVE_TUI_BACKEND"] = "curses"
    assert_equal Hive::Tui::App::CURSES, Hive::Tui::App.backend
  end

  def test_backend_returns_charm_when_env_set
    ENV["HIVE_TUI_BACKEND"] = "charm"
    assert_equal Hive::Tui::App::CHARM, Hive::Tui::App.backend
  end

  def test_backend_strips_whitespace_around_env_value
    ENV["HIVE_TUI_BACKEND"] = "  charm  "
    assert_equal Hive::Tui::App::CHARM, Hive::Tui::App.backend
  end

  def test_unknown_backend_raises_typed_error_with_usage_exit_code
    ENV["HIVE_TUI_BACKEND"] = "ratatui-but-not-here-yet"
    err = assert_raises(Hive::InvalidTaskPath) { Hive::Tui::App.backend }
    assert_match(/unknown HIVE_TUI_BACKEND/, err.message)
    assert_equal Hive::ExitCodes::USAGE, err.exit_code
  end

  # `run_charm` boots a real Bubble Tea runner that wants a tty;
  # the actual lifecycle is exercised by the PTY-based smoke tests
  # (`test/integration/tui_smoke_charm_test.rb`). Here we pin the
  # symbol surface — that the method exists and the entry point
  # contract (no args, public) hasn't drifted.
  def test_run_charm_method_exists_on_app
    assert_respond_to Hive::Tui::App, :run_charm,
      "App.run_charm is the charm backend entry point — App.run delegates here"
  end
end
