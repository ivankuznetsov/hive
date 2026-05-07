require "test_helper"
require "json"
require "open3"
require "tmpdir"

# Integration test for `hive daemon` subcommands. Uses real bin/hive
# subprocesses against a temporary HIVE_HOME so PID file / log file
# manipulation doesn't touch the user's actual ~/Dev/hive/.
class HiveDaemonCommandTest < Minitest::Test
  include HiveTestHelper

  REPO_ROOT = File.expand_path("../..", __dir__)
  HIVE_BIN = File.join(REPO_ROOT, "bin", "hive")

  def with_isolated_hive_home(&block)
    Dir.mktmpdir("hive-daemon-test") do |home|
      env = ENV.to_h.merge("HIVE_HOME" => home)
      block.call(home, env)
    end
  end

  # ── status: not running by default ────────────────────────────────────

  def test_status_returns_not_running_with_exit_1_when_no_daemon
    with_isolated_hive_home do |_home, env|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "status")
      assert_includes out, "not running"
      assert_equal 1, status.exitstatus, "status with no daemon must exit 1"
    end
  end

  def test_status_json_returns_running_false_envelope
    with_isolated_hive_home do |home, env|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "status", "--json")
      # status with --json still raises Hive::Error on not-running
      # (exit 1) but the JSON envelope is on stdout.
      doc = JSON.parse(out)
      assert_equal "hive-daemon-status", doc["schema"]
      assert_equal false, doc["running"]
      assert_equal File.join(home, ".daemon.pid"), doc["pid_file"]
      assert_equal 1, status.exitstatus
    end
  end

  # ── stop: idempotent when not running ─────────────────────────────────

  def test_stop_when_not_running_is_idempotent
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop")
      assert_equal 0, status.exitstatus, "stop with no daemon must exit 0 (idempotent)"
      assert_match(/daemon not running/, err)
    end
  end

  def test_stop_with_stale_pid_file_cleans_up
    with_isolated_hive_home do |home, env|
      # Bare-integer PID format (back-compat path for older daemon
      # versions) pointing at a process that doesn't exist.
      File.write(File.join(home, ".daemon.pid"), "999999")
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop")
      assert_equal 0, status.exitstatus
      assert_match(/stale/, err)
      refute File.exist?(File.join(home, ".daemon.pid")), "stale PID file must be removed"
    end
  end

  def test_stop_with_yaml_pid_payload_for_dead_pid_cleans_up
    # PR-40 review P2 #3: new daemons write a YAML payload (pid +
    # process_start_time + started_at). A YAML payload pointing at a
    # dead PID is the same scenario as the bare-int legacy path.
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: 999999
        process_start_time: "1234567890"
        started_at: "2026-05-06T20:00:00Z"
      YAML
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop")
      assert_equal 0, status.exitstatus
      assert_match(/stale|not alive/, err)
      refute File.exist?(File.join(home, ".daemon.pid")), "stale PID file must be removed"
    end
  end

  def test_stop_refuses_signal_when_pid_reused
    # PR-40 review P2 #3: PID file points at a live PID, but the
    # recorded process_start_time differs from the live process's
    # start_time → another process took over the PID. Don't TERM it.
    # Use the test runner's own PID with a fake/wrong start_time.
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: #{Process.pid}
        process_start_time: "definitely-not-the-real-start-time-#{rand(100_000)}"
        started_at: "2026-05-06T20:00:00Z"
      YAML
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop")
      assert_equal 0, status.exitstatus, "stop must not fail when refusing a reused PID"
      assert_match(/reused/, err.downcase)
      # Test process is still alive — we never sent it SIGTERM.
      assert Process.kill(0, Process.pid),
             "the test runner process must NOT have received SIGTERM"
      refute File.exist?(File.join(home, ".daemon.pid")), "stale PID file removed"
    end
  end

  def test_stop_refuses_signal_when_pid_ownership_unverified
    # PR-40 follow-up review C5: when the recorded process_start_time
    # is nil (a daemon that started in a stripped container without
    # /proc and `ps` — pre-fix this would write nil and the verifier
    # would short-circuit to "trust"), `stop` must refuse to signal
    # the PID rather than risk hitting an unrelated process that was
    # handed the same PID after reuse. Test process must NOT be TERMed.
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: #{Process.pid}
        process_start_time:
        started_at: "2026-05-07T00:00:00Z"
      YAML
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop")
      assert_equal 0, status.exitstatus
      assert_match(/cannot verify/i, err)
      assert Process.kill(0, Process.pid), "test process must NOT have been signaled"
      # Unverified does NOT remove the PID file — operator must
      # confirm + clean up manually per the warn message.
      assert File.exist?(File.join(home, ".daemon.pid")),
             "unverified ownership leaves the PID file in place for operator inspection"
    end
  end

  def test_reload_refuses_when_pid_ownership_unverified
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: #{Process.pid}
        process_start_time:
        started_at: "2026-05-07T00:00:00Z"
      YAML
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload")
      assert_equal 1, status.exitstatus, "reload exits 1 on unverified PID"
      assert_match(/cannot verify|unverified/i, err)
    end
  end

  # ── reload: refuses when daemon not running ───────────────────────────

  def test_reload_when_not_running_exits_1
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload")
      assert_equal 1, status.exitstatus
      assert_match(/daemon not running/, err)
    end
  end

  # ── tail: refuses when log doesn't exist ──────────────────────────────

  def test_tail_when_log_missing_exits_1
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "tail")
      assert_equal 1, status.exitstatus
      assert_match(/log file not found/, err)
    end
  end

  # ── unknown subcommand ────────────────────────────────────────────────

  def test_unknown_subcommand_returns_usage_error
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "frobnicate")
      assert_equal 64, status.exitstatus
      assert_match(/unknown subcommand/, err)
    end
  end
end
