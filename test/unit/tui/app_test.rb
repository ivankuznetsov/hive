require "test_helper"
require "hive/tui/app"

# `Hive::Tui::App` is the charm-only TUI dispatcher after U11 of plan
# #003. Pre-U11 it routed between curses and charm based on
# `HIVE_TUI_BACKEND`; the env var now serves only as a graceful-error
# pointer for users still typing `HIVE_TUI_BACKEND=curses`.
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
    ENV.delete("HIVE_TUI_BACKEND")
    assert_equal Hive::Tui::App::CHARM, Hive::Tui::App.backend
  end

  def test_backend_returns_charm_when_env_set_explicitly
    ENV["HIVE_TUI_BACKEND"] = "charm"
    assert_equal Hive::Tui::App::CHARM, Hive::Tui::App.backend
  end

  def test_backend_strips_whitespace_around_env_value
    ENV["HIVE_TUI_BACKEND"] = "  charm  "
    assert_equal Hive::Tui::App::CHARM, Hive::Tui::App.backend
  end

  # The curses backend was removed in U11. A user who still types
  # `HIVE_TUI_BACKEND=curses` should get a typed error pointing at the
  # removal — not a confusing "unknown backend" message and not a
  # silent fallback to charm.
  def test_curses_backend_raises_typed_removal_error
    ENV["HIVE_TUI_BACKEND"] = "curses"
    err = assert_raises(Hive::InvalidTaskPath) { Hive::Tui::App.backend }
    assert_match(/curses backend was removed/i, err.message)
    assert_match(/charm is the only supported backend/i, err.message)
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
      "App.run_charm is the only TUI backend after U11"
  end

  def test_charm_uses_paste_aware_runner
    assert_equal "Hive::Tui::PasteAwareRunner", Hive::Tui::App.runner_class.name
  end
end
