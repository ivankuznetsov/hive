require_relative "../../test_helper"
require "rbconfig"
require "tmpdir"
require_relative "tmux_driver"

class E2ETmuxDriverTest < Minitest::Test
  COLS = 200
  ROWS = 50
  RUN_ID = "test-#{Process.pid}-#{Time.now.to_i}"

  def setup
    @drivers = []
  end

  def teardown
    @drivers.each(&:cleanup)
  end

  def make_driver(session_name:, command: "bash --noprofile --norc", prompt: "[bash]> ")
    # PS1 explicitly NOT ending in `$ ` or `# ` so the PaneCollapsedError
    # heuristic doesn't trip during normal shell idle. The two collapse-
    # detection tests use a real shell-shaped prompt or a dying session.
    driver = Hive::E2E::TmuxDriver.new(
      run_id: "#{RUN_ID}-#{session_name}",
      session_name: session_name,
      command: command,
      env: { "PS1" => prompt, "TERM" => "xterm-256color" },
      rows: ROWS, cols: COLS
    )
    @drivers << driver
    driver
  end

  def test_send_keys_then_anchor_match
    driver = make_driver(session_name: "happy")
    driver.send_keys([ "echo", "Space", "hive-anchor-token", "Enter" ])
    result = driver.wait_for(anchor: "hive-anchor-token", timeout: 5.0, allow_stable: false, require_stable: true)

    assert_equal :ok, result, "anchor should match after echo"
  end

  def test_settled_state_requires_two_stable_polls
    driver = make_driver(session_name: "settle")
    driver.send_keys([ "echo", "Space", "settle-token", "Enter" ])
    # require_stable forces a confirmation poll where confirm == last AND
    # contains the anchor; reaching :ok means at least two stable captures.
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    driver.wait_for(anchor: "settle-token", timeout: 5.0, interval: 0.1, allow_stable: false, require_stable: true)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :>=, 0.1,
      "stabilisation should add at least one inter-poll interval"
  end

  def test_anchor_timeout_within_budget
    # Use a long-running command WITHOUT a shell prompt so the
    # PaneCollapsedError guard doesn't fire — we want to exercise the
    # AnchorTimeout path specifically.
    driver = make_driver(session_name: "timeout", command: "sleep 30")
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Hive::E2E::TmuxDriver::AnchorTimeout) do
      # allow_stable: false — under e2e use the harness asks `tui_expect`
      # to wait for an anchor explicitly, not "any stable screen".
      driver.wait_for(anchor: "anchor-that-never-appears", timeout: 0.5,
                      interval: 0.05, allow_stable: false, require_stable: false)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 2.0, "timeout should fire near the budget, was #{elapsed}s"
    assert_equal "anchor-that-never-appears", error.anchor
  end

  def test_liveness_guard_fails_fast_on_dead_session
    # Use a real `$ ` prompt so PaneCollapsedError fires when the inner
    # shell exits and bash redraws the prompt sentinel into the pane tail.
    driver = make_driver(session_name: "deadsess", prompt: "$ ")
    # exit the shell — the pane will collapse to a session-closed state OR
    # a tail line ending in the prompt sentinel; either is failure-fast.
    driver.send_keys([ "exit", "Enter" ])
    sleep 0.3

    assert_raises(StandardError) do
      driver.wait_for(anchor: "marker-token-that-no-longer-exists", timeout: 1.0, interval: 0.05)
    end
  end

  def test_cleanup_is_idempotent
    driver = make_driver(session_name: "idempotent")
    driver.send_keys([ "echo", "hi", "Enter" ])
    driver.cleanup
    # double-cleanup must not raise
    driver.cleanup
  end

  def test_pane_geometry_matches_constructor
    driver = make_driver(session_name: "geom")
    # Ask the shell to print COLUMNS, then assert capture-pane width is 200.
    driver.send_keys([ "stty Space cols Space 200 Space rows Space 50", "Enter" ])
    sleep 0.1
    pane = driver.capture_pane
    longest_line_width = pane.lines.map { |line| line.chomp.length }.max || 0

    assert_operator longest_line_width, :<=, COLS,
      "pane lines should not exceed configured cols (#{COLS}); longest was #{longest_line_width}"
  end

  def test_start_injects_path_env_into_command
    Dir.mktmpdir("tmux-env") do |dir|
      output = File.join(dir, "path.txt")
      command = Shellwords.join([
        RbConfig.ruby,
        "-e",
        "File.write(ARGV.fetch(0), ENV.fetch('PATH'))",
        output
      ])
      driver = make_driver(session_name: "envpath", command: command)
      driver.instance_variable_set(:@env, { "PATH" => "/tmp/hive-env-sentinel" })
      driver.start

      deadline = Time.now + 2
      sleep 0.05 until File.exist?(output) || Time.now >= deadline

      assert_includes File.read(output).split(":"), "/tmp/hive-env-sentinel"
    end
  end

  def test_wait_for_subprocess_exit_observes_log_marker_without_pane_death
    Dir.mktmpdir("tmux-subprocess") do |dir|
      log_path = File.join(dir, "hive-tui-subprocess.log")
      driver = make_driver(session_name: "subprocess-log", command: "sleep 30")
      driver.instance_variable_set(:@subprocess_log_path, log_path)
      driver.mark_subprocess_log!
      writer = Thread.new do
        sleep 0.2
        # Production TUI always emits BEGIN before END; the driver binds the
        # observed END to the BEGIN id so a stray END from a prior subprocess
        # cannot be mistaken for completion of the current dispatch.
        File.write(
          log_path,
          "----- 2026-04-30T00:00:00Z BEGIN[deadbeef]: hive plan slug -----\n" \
          "----- 2026-04-30T00:00:00Z END[deadbeef] exit=0: hive plan slug -----\n"
        )
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal :ok, driver.wait_for_subprocess_exit(timeout: 2.0, interval: 0.05)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator elapsed, :<, 1.5, "log marker should resolve before the sleeping TUI pane exits"
      assert driver.capture_pane, "pane should still be alive after background subprocess completion"
      writer.join
    end
  end

  # Non-zero END exit must surface as SubprocessFailed, not :ok. Without
  # the bind-to-BEGIN-id check the previous code treated any END regex
  # match as success regardless of exit_code, silently masking failures.
  def test_wait_for_subprocess_exit_raises_on_nonzero_end_exit
    Dir.mktmpdir("tmux-subprocess") do |dir|
      log_path = File.join(dir, "hive-tui-subprocess.log")
      driver = make_driver(session_name: "subprocess-log-fail", command: "sleep 30")
      driver.instance_variable_set(:@subprocess_log_path, log_path)
      driver.mark_subprocess_log!
      Thread.new do
        sleep 0.1
        File.write(
          log_path,
          "----- 2026-04-30T00:00:00Z BEGIN[cafef00d]: hive plan slug -----\n" \
          "----- 2026-04-30T00:00:00Z END[cafef00d] exit=1: hive plan slug -----\n"
        )
      end.tap { |t| t.join }

      err = assert_raises(Hive::E2E::TmuxDriver::SubprocessFailed) do
        driver.wait_for_subprocess_exit(timeout: 2.0, interval: 0.05)
      end
      assert_equal "cafef00d", err.begin_id
      assert_equal 1, err.exit_code
    end
  end

  # ERRNO appearing in the watched window means the subprocess crashed
  # before reaching END. Treat it as an abnormal-exit failure, not silent
  # success.
  def test_wait_for_subprocess_exit_raises_on_errno_marker
    Dir.mktmpdir("tmux-subprocess") do |dir|
      log_path = File.join(dir, "hive-tui-subprocess.log")
      driver = make_driver(session_name: "subprocess-log-errno", command: "sleep 30")
      driver.instance_variable_set(:@subprocess_log_path, log_path)
      driver.mark_subprocess_log!
      Thread.new do
        sleep 0.1
        File.write(
          log_path,
          "----- 2026-04-30T00:00:00Z BEGIN[abadbabe]: hive plan slug -----\n" \
          "----- 2026-04-30T00:00:00Z ERRNO Errno::ENOENT: no such file -----\n"
        )
      end.tap { |t| t.join }

      assert_raises(Hive::E2E::TmuxDriver::SubprocessAbnormal) do
        driver.wait_for_subprocess_exit(timeout: 2.0, interval: 0.05)
      end
    end
  end
end
