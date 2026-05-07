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

  # ── enable / disable: per-project YAML toggle ─────────────────────────

  # Sets up a HIVE_HOME with one registered project at <home>/proj
  # carrying a minimal `.hive-state/config.yml`. Yields the env hash
  # plus the project's config.yml path so each test can assert against
  # the post-toggle YAML.
  def with_registered_project(initial_yaml: "default_branch: main\n")
    with_isolated_hive_home do |home, env|
      project_root = File.join(home, "proj")
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      cfg_path = File.join(hive_state, "config.yml")
      File.write(cfg_path, initial_yaml)
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [
          { "name" => "proj", "path" => project_root, "hive_state_path" => hive_state }
        ]
      }.to_yaml)
      yield(env, cfg_path, project_root)
    end
  end

  def test_enable_sets_daemon_enabled_true_in_project_yaml
    with_registered_project do |env, cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus
      assert_match(/enabled proj/, out)

      data = YAML.safe_load(File.read(cfg_path))
      assert_equal true, data.dig("daemon", "enabled")
      assert_equal "main", data["default_branch"], "must preserve other keys"
    end
  end

  def test_disable_sets_daemon_enabled_false
    with_registered_project(initial_yaml: <<~YAML) do |env, cfg_path, _root|
      default_branch: main
      daemon:
        enabled: true
    YAML
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "disable", "proj")
      assert_equal 0, status.exitstatus
      assert_match(/disabled proj/, out)
      data = YAML.safe_load(File.read(cfg_path))
      assert_equal false, data.dig("daemon", "enabled")
    end
  end

  def test_enable_is_idempotent_and_preserves_unrelated_daemon_keys
    # Pre-existing daemon block with non-default tunables — enable
    # must NOT clobber them, only flip `enabled`.
    with_registered_project(initial_yaml: <<~YAML) do |env, cfg_path, _root|
      default_branch: main
      daemon:
        enabled: false
        poll_interval_sec: 60
        max_concurrent_runs: 5
    YAML
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus
      data = YAML.safe_load(File.read(cfg_path))
      assert_equal true, data.dig("daemon", "enabled")
      assert_equal 60, data.dig("daemon", "poll_interval_sec"), "tunables preserved"
      assert_equal 5, data.dig("daemon", "max_concurrent_runs"), "tunables preserved"
    end
  end

  def test_enable_rejects_malformed_project_yaml_as_config_error
    with_registered_project(initial_yaml: "daemon:\n  enabled: [\n") do |env, _cfg_path, _root|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_match(/not valid YAML/, err)
      refute_match(/Psych::SyntaxError/, err)
    end
  end

  def test_enable_rejects_non_hash_project_yaml_without_overwriting
    original = "- not\n- a\n- hash\n"
    with_registered_project(initial_yaml: original) do |env, cfg_path, _root|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_match(/must be a hash/, err)
      assert_equal original, File.read(cfg_path)
    end
  end

  def test_enable_missing_target_without_all_exits_usage
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable")
      assert_equal 64, status.exitstatus
      assert_match(/missing PROJECT/, err)
    end
  end

  def test_enable_unknown_project_exits_usage
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "nope")
      assert_equal 64, status.exitstatus
      assert_match(/unknown project "nope"/, err)
    end
  end

  def test_enable_all_targets_every_registered_project
    with_isolated_hive_home do |home, env|
      projects = %w[a b c].map do |name|
        root = File.join(home, name)
        FileUtils.mkdir_p(File.join(root, ".hive-state"))
        File.write(File.join(root, ".hive-state", "config.yml"), "default_branch: main\n")
        { "name" => name, "path" => root, "hive_state_path" => File.join(root, ".hive-state") }
      end
      File.write(File.join(home, "config.yml"), { "registered_projects" => projects }.to_yaml)

      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "--all")
      assert_equal 0, status.exitstatus
      %w[a b c].each do |name|
        assert_match(/enabled #{name}/, out)
        data = YAML.safe_load(File.read(File.join(home, name, ".hive-state", "config.yml")))
        assert_equal true, data.dig("daemon", "enabled"), "#{name} must be enabled"
      end
    end
  end

  def test_disable_all_preflights_every_project_before_writing
    with_isolated_hive_home do |home, env|
      projects = %w[a broken c].map do |name|
        root = File.join(home, name)
        hive_state = File.join(root, ".hive-state")
        unless name == "broken"
          FileUtils.mkdir_p(hive_state)
          File.write(File.join(hive_state, "config.yml"), <<~YAML)
            default_branch: main
            daemon:
              enabled: true
          YAML
        end
        { "name" => name, "path" => root, "hive_state_path" => hive_state }
      end
      File.write(File.join(home, "config.yml"), { "registered_projects" => projects }.to_yaml)

      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "disable", "--all")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_match(/missing .*broken.*config.yml/, err)

      %w[a c].each do |name|
        data = YAML.safe_load(File.read(File.join(home, name, ".hive-state", "config.yml")))
        assert_equal true, data.dig("daemon", "enabled"), "#{name} must not be changed after preflight failure"
      end
    end
  end

  def test_enable_all_with_empty_registry_exits_usage
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "--all")
      assert_equal 64, status.exitstatus
      assert_match(/no registered projects/, err)
    end
  end

  def test_enable_json_envelope_shape
    with_registered_project do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "hive-daemon-enroll", doc["schema"]
      assert_equal 1, doc["schema_version"]
      assert_equal true, doc["ok"]
      assert_equal "enable", doc["subcommand"]
      assert_equal 1, doc["results"].size
      result = doc["results"].first
      assert_equal "proj", result["name"]
      assert_nil result["previous"], "previous was unset (no daemon block) → nil"
      assert_equal true, result["current"]
    end
  end
end
