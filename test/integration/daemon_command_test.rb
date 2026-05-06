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
      # Write a PID file pointing at a process that doesn't exist
      File.write(File.join(home, ".daemon.pid"), "999999")
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop")
      assert_equal 0, status.exitstatus
      assert_match(/stale/, err)
      refute File.exist?(File.join(home, ".daemon.pid")), "stale PID file must be removed"
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
