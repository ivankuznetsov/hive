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
  def test_snapshot_poller_dispatches_poll_failures
    require "hive/tui/messages"
    state_source = PollerStateSource.new(error: RuntimeError.new("poll failed"))
    runner = RecordingRunner.new
    poller = Hive::Tui::App.start_snapshot_poller(state_source, runner)

    wait_until { runner.messages.any? }

    message = runner.messages.first
    assert_kind_of Hive::Tui::Messages::PollFailed, message
    assert_equal "poll failed", message.error.message
  ensure
    poller&.kill
    poller&.join
  end

  def test_snapshot_poller_rescues_state_source_errors_and_stays_alive
    state_source = RaisingStateSource.new
    runner = RecordingRunner.new
    poller = Hive::Tui::App.start_snapshot_poller(state_source, runner)

    wait_until { state_source.calls.positive? }

    assert poller.alive?, "poller should continue after a transient StateSource exception"
  ensure
    poller&.kill
    poller&.join
  end

  def test_install_terminate_hook_enqueues_terminate_requested
    require "hive/tui/messages"
    runner = RecordingRunner.new
    captured = nil
    original = Signal.singleton_class.instance_method(:trap)
    Signal.define_singleton_method(:trap) do |signal_name, *_args, &block|
      captured = block if signal_name == "HUP"
      :previous_hup
    end

    previous = Hive::Tui::App.install_terminate_hook(runner)
    captured.call

    assert_equal :previous_hup, previous
    assert_equal [ Hive::Tui::Messages::TERMINATE_REQUESTED ], runner.messages
  ensure
    Signal.singleton_class.define_method(:trap, original) if original
  end

  def test_restore_terminate_hook_swallows_invalid_previous_handler
    original = Signal.singleton_class.instance_method(:trap)
    Signal.define_singleton_method(:trap) do |_signal_name, _handler|
      raise ArgumentError, "invalid signal handler"
    end

    assert_nil Hive::Tui::App.restore_terminate_hook(:bad_handler)
  ensure
    Signal.singleton_class.define_method(:trap, original) if original
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    until yield
      raise "condition not met within #{timeout}s" if Time.now >= deadline

      sleep 0.01
    end
  end

  class RecordingRunner
    attr_reader :messages

    def initialize
      @messages = []
      @mutex = Mutex.new
    end

    def send(message)
      @mutex.synchronize { @messages << message }
    end
  end

  class PollerStateSource
    attr_reader :last_error

    def initialize(current: nil, error: nil)
      @current = current
      @last_error = error
    end

    def current
      @current
    end
  end

  class RaisingStateSource
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def current
      @calls += 1
      raise RuntimeError, "snapshot unavailable"
    end

    def last_error
      nil
    end
  end
end
