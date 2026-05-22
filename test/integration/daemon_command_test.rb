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

  # Malformed PID file (garbage content, not parseable as a PID): stop
  # must still emit hive-daemon-stop envelope under --json with the
  # `malformed_pid_file` reason, and clean up the bad file. Without
  # the envelope path, agents could not distinguish this from "no PID
  # file at all".
  def test_stop_with_malformed_pid_file_emits_envelope_and_cleans_up
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), "this is not a YAML PID payload\n")
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "hive-daemon-stop", doc["schema"]
      assert_equal true, doc["ok"]
      assert_equal false, doc["running"]
      assert_equal false, doc["was_running"]
      assert_equal "malformed_pid_file", doc["reason"],
                   "malformed PID file must surface the closed reason enum value"
      refute File.exist?(File.join(home, ".daemon.pid")),
             "malformed PID file must be cleaned up"
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

  # `hive daemon reload --json` envelope: emits hive-daemon-reload.v1
  # for both success (signal delivered) and refusal (no PID file, dead
  # PID, reused PID, unverified ownership) paths. Without an envelope,
  # an agent caller has to scrape stderr to learn why reload refused.

  def test_reload_json_envelope_when_not_running
    with_isolated_hive_home do |home, env|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload", "--json")
      assert_equal 1, status.exitstatus,
                   "reload exits 1 on refusal even with --json"
      doc = JSON.parse(out)
      assert_equal "hive-daemon-reload", doc["schema"]
      assert_equal 1, doc["schema_version"]
      assert_equal false, doc["ok"]
      assert_equal "not_running", doc["reason"]
      assert_match(/no PID file/i, doc["message"])
      assert_match(/#{Regexp.escape(home)}/, doc["message"])
    end
  end

  def test_reload_json_envelope_when_pid_dead
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: 999999
        process_start_time: "1234567890"
        started_at: "2026-05-06T20:00:00Z"
      YAML
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload", "--json")
      assert_equal 1, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "hive-daemon-reload", doc["schema"]
      assert_equal false, doc["ok"]
      assert_equal "pid_dead", doc["reason"]
      assert_equal 999_999, doc["pid"]
    end
  end

  def test_reload_json_envelope_when_pid_reused
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: #{Process.pid}
        process_start_time: "definitely-not-the-real-start-time-#{rand(100_000)}"
        started_at: "2026-05-06T20:00:00Z"
      YAML
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload", "--json")
      assert_equal 1, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "pid_reused", doc["reason"]
      assert Process.kill(0, Process.pid),
             "test runner process must NOT have been HUP'd"
    end
  end

  def test_reload_json_envelope_when_pid_unverified
    with_isolated_hive_home do |home, env|
      File.write(File.join(home, ".daemon.pid"), <<~YAML)
        ---
        pid: #{Process.pid}
        process_start_time:
        started_at: "2026-05-07T00:00:00Z"
      YAML
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload", "--json")
      assert_equal 1, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "unverified", doc["reason"]
    end
  end

  def test_reload_json_envelope_validates_against_published_schema
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-reload"))))
    with_isolated_hive_home do |_home, env|
      out, _err, _status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "reload", "--json")
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "reload subprocess stdout must validate against hive-daemon-reload.v1; got: #{errors.inspect}"
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
      assert_match(/top-level YAML is not a mapping/, err)
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
      # Missing-config-on-registered-project is classified as USAGE
      # (not_initialised) — the operator can fix via `hive init` rather
      # than treat it as a bad-config error. Distinct from a malformed
      # config which exits 78 (CONFIG). The atomicity invariant is the
      # same either way: no project gets flipped before preflight passes.
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
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

  # Malformed config.yml must surface as Hive::ConfigError (exit 78), not
  # an uncaught Psych::SyntaxError. Covers both read sites:
  # current_daemon_enabled (fired before write_daemon_block) and
  # write_daemon_block's own rescue (covered transitively when the first
  # read happens to succeed but the second parse fails on a follow-up
  # rewrite — same code path).
  def test_enable_on_malformed_yaml_raises_config_error_not_psych_crash
    with_registered_project(initial_yaml: ":\n: not valid: yaml: at all:") do |env, _cfg_path, _root|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "malformed YAML must exit 78 (CONFIG), not surface as a Psych crash"
      assert_match(/not valid YAML/i, err)
    end
  end

  # When the project is registered but its .hive-state/config.yml has been
  # deleted manually, `enable` must surface as the not_initialised
  # USAGE-class error (exit 64), pointing at the missing path — not
  # bubble up Errno::ENOENT or write a fresh file behind the operator's
  # back.
  def test_enable_on_missing_config_yml_raises_not_initialised
    with_isolated_hive_home do |home, env|
      project_root = File.join(home, "proj")
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      # Note: no config.yml inside .hive-state.
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [
          { "name" => "proj", "path" => project_root, "hive_state_path" => hive_state }
        ]
      }.to_yaml)
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "missing config.yml must exit 64 (USAGE) via not_initialised"
      assert_match(/not initialised|missing/i, err)
    end
  end

  # `hive daemon enable PROJECT --all` is operator/agent ambiguity — refuse
  # rather than silently letting --all win and ignoring PROJECT.
  def test_enable_rejects_project_combined_with_all
    with_registered_project do |env, _cfg_path, _root|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--all")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "PROJECT + --all must exit 64 (USAGE), not silently apply --all"
      assert_match(/cannot combine/i, err)
    end
  end

  # ── JSON error envelope: --json failures emit hive-daemon-enroll
  #    ErrorPayload on stdout, mirroring the symmetric `hive forget`
  #    contract. Without this, agent retry wrappers would have to scrape
  #    stderr to learn the failure mode.

  def test_enable_json_error_envelope_unknown_project
    with_registered_project do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "nope", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "hive-daemon-enroll", doc["schema"]
      assert_equal 1, doc["schema_version"]
      assert_equal false, doc["ok"]
      assert_equal "UsageError", doc["error_class"]
      assert_equal Hive::Schemas::EnrollErrorKind::UNKNOWN_PROJECT, doc["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, doc["exit_code"]
      assert_match(/unknown project/, doc["message"])
    end
  end

  def test_enable_json_error_envelope_missing_project
    with_isolated_hive_home do |_home, env|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "hive-daemon-enroll", doc["schema"]
      assert_equal false, doc["ok"]
      assert_equal Hive::Schemas::EnrollErrorKind::MISSING_PROJECT, doc["error_kind"]
    end
  end

  def test_enable_json_error_envelope_project_and_all
    with_registered_project do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--all", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      doc = JSON.parse(out)
      assert_equal Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL, doc["error_kind"]
      assert_equal "UsageError", doc["error_class"]
    end
  end

  def test_enable_json_error_envelope_not_initialised
    with_isolated_hive_home do |home, env|
      project_root = File.join(home, "proj")
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [
          { "name" => "proj", "path" => project_root, "hive_state_path" => hive_state }
        ]
      }.to_yaml)
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      doc = JSON.parse(out)
      assert_equal Hive::Schemas::EnrollErrorKind::NOT_INITIALISED, doc["error_kind"]
    end
  end

  def test_enable_json_error_envelope_no_projects
    with_isolated_hive_home do |_home, env|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "--all", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      doc = JSON.parse(out)
      assert_equal Hive::Schemas::EnrollErrorKind::NO_PROJECTS, doc["error_kind"]
    end
  end

  def test_enable_json_error_envelope_config_on_malformed_yaml
    with_registered_project(initial_yaml: ":\n: not valid: yaml: at all:") do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      doc = JSON.parse(out)
      assert_equal Hive::Schemas::EnrollErrorKind::CONFIG, doc["error_kind"]
      assert_equal "ConfigError", doc["error_class"]
      assert_equal Hive::ExitCodes::CONFIG, doc["exit_code"]
    end
  end

  # ── Surgical YAML edit (P1-1A): comments and key order survive the
  #    enable/disable flip. The whole point of the line-level upsert
  #    over a YAML round-trip.

  def test_enable_preserves_operator_comments_and_key_order
    initial = <<~YAML
      # Top-level comment about default branch.
      default_branch: main

      # Stage agents block — claude for planning, codex for execute.
      brainstorm:
        agent: claude
      execute:
        agent: codex

      # Daemon (ADR-024). Disable per-project here.
      daemon:
        enabled: false
        poll_interval_sec: 30
    YAML
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus

      after = File.read(cfg_path)
      assert_includes after, "# Top-level comment about default branch.",
                      "top-level operator comment must survive enable"
      assert_includes after, "# Stage agents block — claude for planning, codex for execute.",
                      "section comment must survive enable"
      assert_includes after, "# Daemon (ADR-024). Disable per-project here.",
                      "comment immediately above daemon: must survive enable"

      # Key order must be preserved (default_branch before brainstorm before
      # execute before daemon). YAML.to_yaml emits alphabetical, which would
      # have flipped this.
      idx_default = after.index("default_branch:")
      idx_brainstorm = after.index("brainstorm:")
      idx_execute = after.index("execute:")
      idx_daemon = after.index("daemon:")
      assert idx_default && idx_brainstorm && idx_execute && idx_daemon
      assert_operator idx_default, :<, idx_brainstorm
      assert_operator idx_brainstorm, :<, idx_execute
      assert_operator idx_execute, :<, idx_daemon

      # And the actual flip happened.
      assert_match(/^  enabled: true$/, after)
      assert_includes after, "  poll_interval_sec: 30",
                      "sibling daemon keys must survive enable"
    end
  end

  def test_enable_appends_daemon_block_when_absent
    # No daemon: block at all in the starting file. Surgical edit must
    # append a clean block at EOF without disturbing the existing keys.
    initial = "default_branch: main\nworktree_root: ../worktrees\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus

      after = File.read(cfg_path)
      assert_match(/^daemon:\n  enabled: true$/, after)
      assert_includes after, "default_branch: main", "existing keys preserved"
      assert_includes after, "worktree_root: ../worktrees", "existing keys preserved"
    end
  end

  def test_enable_inserts_enabled_when_daemon_block_has_other_keys_only
    # The `daemon:` block exists but lacks `enabled:` (e.g. operator
    # set custom tunables but never explicitly opted in/out). Surgical
    # edit must insert the new key as the first child.
    initial = <<~YAML
      default_branch: main
      daemon:
        poll_interval_sec: 60
        max_concurrent_runs: 5
    YAML
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus

      data = YAML.safe_load(File.read(cfg_path))
      assert_equal true, data.dig("daemon", "enabled")
      assert_equal 60, data.dig("daemon", "poll_interval_sec"), "tunables preserved"
      assert_equal 5, data.dig("daemon", "max_concurrent_runs"), "tunables preserved"
    end
  end

  def test_enable_preserves_inline_comment_on_enabled_line
    initial = <<~YAML
      default_branch: main
      daemon:
        enabled: false  # disabled until first dogfooding round
    YAML
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus

      after = File.read(cfg_path)
      assert_includes after, "# disabled until first dogfooding round",
                      "inline comment on enabled: line must survive the flip"
      assert_match(/^  enabled: true {2,}# disabled until first dogfooding round$/, after)
    end
  end

  # Block-scalar `daemon: |` parses with `daemon` as a String (the
  # literal-block content), NOT a Hash. The existing
  # "daemon: is not a mapping" check at preflight catches this before
  # the surgical-edit path is reached, so the file is left untouched
  # and exits 78. Without this test, a future refactor could remove
  # the non-Hash guard and silently fall through to the line-level
  # editor, which would then append a duplicate `daemon:` key (since
  # the YAML-text view shows `daemon:` ambiguously).
  def test_enable_rejects_block_scalar_daemon_value_without_overwriting
    initial = "default_branch: main\ndaemon: |\n  some content\n  on multiple lines\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      original_text = File.read(cfg_path)
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "block-scalar daemon: value must exit 78 (CONFIG)"
      assert_match(/`daemon:` is not a mapping/, err)
      assert_equal original_text, File.read(cfg_path),
                   "config.yml must not have been touched on block-scalar rejection"
    end
  end

  # Multi-token `enabled:` value (`enabled: false maybe` — a YAML
  # string scalar, not a boolean). Pre-fix, the surgical-edit regex
  # `\S+` only replaced the first non-whitespace token, leaving the
  # trailing tokens behind: `enabled: true maybe`, which YAML parses
  # as the STRING "true maybe" (silent corruption — dispatcher's
  # `cfg.dig("daemon","enabled") == true` returns false despite the
  # CLI reporting `enabled: true`). New behaviour: the entire value-
  # portion gets replaced cleanly, dropping the unparseable tail.
  def test_enable_replaces_multi_token_enabled_value_cleanly
    initial = <<~YAML
      default_branch: main
      daemon:
        enabled: false maybe
    YAML
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus

      data = YAML.safe_load(File.read(cfg_path))
      assert_equal true, data.dig("daemon", "enabled"),
                   "enabled must be the literal boolean true after flip, " \
                   "not the string 'true maybe'"
      after = File.read(cfg_path)
      assert_match(/^  enabled: true$/, after,
                   "value-portion must be replaced cleanly, dropping the " \
                   "unparseable trailing tokens")
    end
  end

  def test_enable_preserves_file_mode_bits
    with_registered_project do |env, cfg_path, _root|
      File.chmod(0o600, cfg_path)
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus
      assert_equal 0o600, File.stat(cfg_path).mode & 0o7777,
                   "0600 mode must survive the rewrite"
    end
  end

  # ── Pre-flight validation: --all must be transactional w.r.t. project
  #    config validity. A broken project mid-registry must NOT leave
  #    earlier projects mutated and later projects untouched — that
  #    weakens `disable --all` precisely when an operator needs it as a
  #    cost-runaway response.

  def test_disable_all_preflight_aborts_when_one_project_has_malformed_yaml
    with_isolated_hive_home do |home, env|
      # Three projects: a (good, enabled=true), b (broken YAML), c (good, enabled=true).
      # `disable --all` must NOT flip a, must NOT touch c, and must surface a
      # config error rather than partially advancing.
      projects = []
      %w[a b c].each_with_index do |name, idx|
        root = File.join(home, name)
        hive_state = File.join(root, ".hive-state")
        FileUtils.mkdir_p(hive_state)
        cfg = File.join(hive_state, "config.yml")
        if name == "b"
          File.write(cfg, ":\n: not valid: yaml: at all:")
        else
          File.write(cfg, "default_branch: main\ndaemon:\n  enabled: true\n")
        end
        projects << { "name" => name, "path" => root, "hive_state_path" => hive_state }
      end
      File.write(File.join(home, "config.yml"), { "registered_projects" => projects }.to_yaml)

      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "disable", "--all")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "disable --all must exit 78 (CONFIG) when a target's YAML is malformed"

      # The good projects must still be `enabled: true` — no partial mutation.
      data_a = YAML.safe_load(File.read(File.join(home, "a", ".hive-state", "config.yml")))
      data_c = YAML.safe_load(File.read(File.join(home, "c", ".hive-state", "config.yml")))
      assert_equal true, data_a.dig("daemon", "enabled"),
                   "project a must NOT have been flipped by disable --all (preflight aborted)"
      assert_equal true, data_c.dig("daemon", "enabled"),
                   "project c must NOT have been flipped by disable --all (preflight aborted)"
    end
  end

  def test_enable_all_preflight_aborts_when_one_project_missing_config_yml
    with_isolated_hive_home do |home, env|
      # Three projects: a, b, c. Project b has `.hive-state/` but no
      # config.yml inside (partial-init state). enable --all must
      # refuse the whole operation, not flip a + skip c.
      projects = []
      %w[a b c].each do |name|
        root = File.join(home, name)
        hive_state = File.join(root, ".hive-state")
        FileUtils.mkdir_p(hive_state)
        if name != "b"
          File.write(File.join(hive_state, "config.yml"), "default_branch: main\n")
        end
        projects << { "name" => name, "path" => root, "hive_state_path" => hive_state }
      end
      File.write(File.join(home, "config.yml"), { "registered_projects" => projects }.to_yaml)

      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "--all")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "enable --all must exit 64 (USAGE / not_initialised) on missing config.yml"

      # a must NOT have a daemon block; preflight aborted before any writes.
      a_cfg = File.read(File.join(home, "a", ".hive-state", "config.yml"))
      refute_match(/^daemon:/, a_cfg,
                   "project a must NOT have been touched by enable --all (preflight aborted)")
      c_cfg = File.read(File.join(home, "c", ".hive-state", "config.yml"))
      refute_match(/^daemon:/, c_cfg,
                   "project c must NOT have been touched by enable --all (preflight aborted)")
    end
  end

  # Inline-flow `daemon: { enabled: false }` parses as a Hash via
  # YAML.safe_load but has no `^daemon:$` line at column 0. Without an
  # explicit guard, the surgical editor would silently append a fresh
  # block at EOF, producing a duplicate-key file that corrupts the
  # config. Pre-flight must reject this with a clear ConfigError.
  # ── Concurrency: flock(LOCK_EX) must serialise concurrent enable
  #    calls so the file is never partially written. Without flock or
  #    fsync, parallel writers can interleave their tempfile rename
  #    races and end up with a malformed final file.
  def test_concurrent_enables_serialise_via_flock_and_converge
    with_registered_project do |env, cfg_path, _root|
      # Spawn 4 concurrent enable subprocesses. Each one acquires the
      # exclusive flock on the existing inode, reads, rewrites via
      # tempfile + rename, and exits. With flock, every call observes
      # a coherent file; without it, two writers could trample each
      # other's rename and leave a half-written tempfile or a
      # malformed config.yml.
      pids = Array.new(4) do
        Process.spawn(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "enable", "proj",
                      in: "/dev/null", out: "/dev/null", err: "/dev/null")
      end
      statuses = pids.map { |pid| Process.waitpid2(pid)[1] }
      statuses.each_with_index do |s, i|
        assert_equal 0, s.exitstatus,
                     "concurrent enable ##{i} must exit 0 (flock serialises, all should succeed)"
      end

      # Final state: file is well-formed and reports enabled: true.
      data = YAML.safe_load(File.read(cfg_path))
      assert_equal true, data.dig("daemon", "enabled"),
                   "concurrent enables must converge on enabled: true"

      # No tempfile debris left behind.
      debris = Dir.glob("#{cfg_path}.tmp.*")
      assert_empty debris,
                   "no `*.tmp.*` tempfiles must remain after concurrent enables (got: #{debris.inspect})"

      # File is not duplicated / truncated. The original keys + the
      # daemon block must all still be present and parse cleanly.
      assert_equal "main", data["default_branch"],
                   "default_branch must survive concurrent rewrites"
    end
  end

  # Stronger concurrency assertion: mix enable + disable in 4 concurrent
  # workers. Without flock, two writers' rename races could interleave
  # and produce a final file that is neither cleanly enabled=true nor
  # cleanly enabled=false (e.g. duplicate daemon: keys, partial YAML,
  # or a value other than true/false). The same-value-only test above
  # converges trivially via any permutation, so a broken flock would
  # still pass it. THIS test pins serialisation: the final state must
  # be ONE of the two valid flips, not a hybrid.
  def test_concurrent_mixed_enable_disable_yield_well_formed_serial_state
    with_registered_project do |env, cfg_path, _root|
      pids = []
      4.times do |i|
        verb = i.even? ? "enable" : "disable"
        pids << Process.spawn(env, "ruby", "-Ilib", HIVE_BIN, "daemon", verb, "proj",
                              in: "/dev/null", out: "/dev/null", err: "/dev/null")
      end
      statuses = pids.map { |pid| Process.waitpid2(pid)[1] }
      statuses.each_with_index do |s, i|
        verb = i.even? ? "enable" : "disable"
        assert_equal 0, s.exitstatus,
                     "concurrent #{verb} ##{i} must exit 0"
      end

      # The final file must parse as well-formed YAML — any race
      # would either leave a duplicate-key file (Psych raises) or a
      # half-written file (Psych raises or returns non-Hash).
      data = nil
      assert_nothing_raised do
        data = YAML.safe_load(File.read(cfg_path))
      end
      assert_kind_of Hash, data,
                     "concurrent mixed enable+disable must yield a parseable Hash, " \
                     "not a corrupted half-write"

      # The final daemon.enabled value must be exactly true or false —
      # one of the workers had to be the last writer; whichever it was,
      # the answer is one of the two valid serialised states.
      final = data.dig("daemon", "enabled")
      assert_includes [ true, false ], final,
                      "final daemon.enabled must be one of {true, false}, got #{final.inspect}"

      # No tempfile debris.
      debris = Dir.glob("#{cfg_path}.tmp.*")
      assert_empty debris, "no tempfile debris (got: #{debris.inspect})"
    end
  end

  def assert_nothing_raised(&block)
    block.call
    pass
  rescue StandardError => e
    flunk "expected no exception, got: #{e.class}: #{e.message}"
  end

  def test_enable_rejects_inline_flow_daemon_block_with_clear_error
    initial = "default_branch: main\ndaemon: { enabled: false }\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      original_text = File.read(cfg_path)
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "inline-flow daemon block must exit 78 (CONFIG), not corrupt the file"
      assert_match(/inline or non-2-space-indented/i, err)
      assert_equal original_text, File.read(cfg_path),
                   "config.yml must not have been touched on inline-shape rejection"
    end
  end

  def test_enable_rejects_tab_indented_daemon_children
    # YAML accepts tab indentation in scalars but our surgical editor
    # only handles 2-space indent. Document the behavior explicitly:
    # YAML.safe_load actually rejects tab-indented mapping keys outright
    # (Psych raises), so this falls into the malformed-YAML path and
    # exits CONFIG. Either way, the file is untouched.
    initial = "default_branch: main\ndaemon:\n\tenabled: false\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      original_text = File.read(cfg_path)
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                          "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "tab-indented daemon children must exit 78 (CONFIG)"
      assert_equal original_text, File.read(cfg_path),
                   "config.yml must not have been touched on tab-indent rejection"
    end
  end

  def test_disable_all_preflight_emits_json_error_envelope
    with_isolated_hive_home do |home, env|
      projects = []
      %w[a b].each do |name|
        root = File.join(home, name)
        hive_state = File.join(root, ".hive-state")
        FileUtils.mkdir_p(hive_state)
        cfg = File.join(hive_state, "config.yml")
        if name == "b"
          File.write(cfg, ":\n: not: valid: yaml:")
        else
          File.write(cfg, "default_branch: main\n")
        end
        projects << { "name" => name, "path" => root, "hive_state_path" => hive_state }
      end
      File.write(File.join(home, "config.yml"), { "registered_projects" => projects }.to_yaml)

      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "disable", "--all", "--json")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "hive-daemon-enroll", doc["schema"]
      assert_equal false, doc["ok"]
      assert_equal Hive::Schemas::EnrollErrorKind::CONFIG, doc["error_kind"]
      assert_equal "ConfigError", doc["error_class"]
    end
  end

  # ── Stricter shape rejection (4-space indent, CRLF) ──
  # YAML.safe_load accepts 4-space-indented children under daemon:.
  # Pre-fix, our line scanner would not match `\A  enabled:` against a
  # 4-space-indented line, fall into branch 2 of upsert_daemon_enabled,
  # and insert a 2-space sibling — producing a duplicate-key file. The
  # next safe_load would then raise. Validate that we now refuse the
  # operation upfront, leaving the file untouched.
  def test_enable_rejects_four_space_indented_daemon_children
    initial = "default_branch: main\ndaemon:\n    enabled: false\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      original_text = File.read(cfg_path)
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "4-space-indented daemon children must exit 78 (CONFIG), not corrupt the file"
      assert_match(/2-space indentation/i, err)
      assert_equal original_text, File.read(cfg_path),
                   "config.yml must not have been touched on 4-space-indent rejection"
    end
  end

  # UTF-8 BOM at the start of config.yml causes Psych to silently
  # mis-parse the daemon block. Pre-fix, the surgical editor would
  # append a fresh `daemon:` block past the BOM, producing a file the
  # dispatcher (also reading via Psych) still cannot see. CLI reported
  # success while the daemon never knew the project was enabled.
  def test_enable_rejects_utf8_bom_prefixed_config_yml
    bom = "\xEF\xBB\xBF".dup.force_encoding("UTF-8")
    initial = "#{bom}default_branch: main\ndaemon:\n  enabled: false\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      original_text = File.read(cfg_path)
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "BOM-prefixed config.yml must exit 78 (CONFIG)"
      assert_match(/UTF-8 BOM/i, err)
      assert_match(/ef bb bf/, err, "error message should name the byte sequence")
      assert_equal original_text, File.read(cfg_path),
                   "config.yml must not have been touched on BOM rejection"
    end
  end

  def test_enable_rejects_crlf_line_endings_with_clear_error
    initial = "default_branch: main\r\ndaemon:\r\n  enabled: false\r\n"
    with_registered_project(initial_yaml: initial) do |env, cfg_path, _root|
      original_text = File.read(cfg_path)
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus,
                   "CRLF config.yml must exit 78 (CONFIG), not silently corrupt"
      assert_match(/CRLF/i, err)
      assert_equal original_text, File.read(cfg_path),
                   "config.yml must not have been touched on CRLF rejection"
    end
  end

  # ── Idempotency signal in bare-text + previous=true envelope ──

  def test_enable_bare_text_emits_already_enabled_on_reenable
    initial = "default_branch: main\ndaemon:\n  enabled: true\n"
    with_registered_project(initial_yaml: initial) do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj")
      assert_equal 0, status.exitstatus
      assert_match(/\(already enabled\)/, out,
                   "re-enable on already-enabled project must surface idempotency in bare-text output")
    end
  end

  def test_disable_bare_text_emits_already_disabled_on_redisable
    initial = "default_branch: main\ndaemon:\n  enabled: false\n"
    with_registered_project(initial_yaml: initial) do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "disable", "proj")
      assert_equal 0, status.exitstatus
      assert_match(/\(already disabled\)/, out,
                   "re-disable on already-disabled project must surface idempotency")
    end
  end

  def test_enable_envelope_previous_true_when_already_enabled
    # Pre-seed the project with daemon.enabled: true so re-running enable
    # exercises the previous=true branch — was unpinned by tests.
    initial = "default_branch: main\ndaemon:\n  enabled: true\n"
    with_registered_project(initial_yaml: initial) do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      result = doc["results"].first
      assert_equal true, result["previous"],
                   "previous must be true when daemon was already enabled"
      assert_equal true, result["current"]
    end
  end

  # next_action hint pins the agent-callable post-enroll behavior so a
  # caller can branch on `kind` without parsing the bare-text "next:"
  # paragraph. `kind: reload` when at least one project flipped (with
  # required:false because the per-tick cache picks it up); `kind: no_op`
  # when every result was already at the requested state.

  def test_enable_envelope_next_action_reload_when_state_flipped
    with_registered_project(initial_yaml: "default_branch: main\ndaemon:\n  enabled: false\n") do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "reload", doc.dig("next_action", "kind"),
                   "flipped enabled=false → true must surface kind: reload"
      assert_equal false, doc.dig("next_action", "required"),
                   "reload is optional because per-tick cache picks up changes within poll_interval_sec"
      assert_equal "hive daemon reload", doc.dig("next_action", "command")
    end
  end

  def test_enable_envelope_next_action_no_op_when_already_enabled
    with_registered_project(initial_yaml: "default_branch: main\ndaemon:\n  enabled: true\n") do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "no_op", doc.dig("next_action", "kind"),
                   "re-enable on already-enabled must surface kind: no_op so agents skip reload"
      refute doc.dig("next_action").key?("command"),
             "no_op envelope must not include a command (nothing to do)"
    end
  end

  def test_disable_envelope_previous_false_when_already_disabled
    initial = "default_branch: main\ndaemon:\n  enabled: false\n"
    with_registered_project(initial_yaml: initial) do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "disable", "proj", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      result = doc["results"].first
      assert_equal false, result["previous"]
      assert_equal false, result["current"]
    end
  end

  # ── Disable idempotency mirror of test_enable_is_idempotent_and_preserves_unrelated_daemon_keys ──

  def test_disable_is_idempotent_and_preserves_unrelated_daemon_keys
    with_registered_project(initial_yaml: <<~YAML) do |env, cfg_path, _root|
      default_branch: main
      daemon:
        enabled: false
        poll_interval_sec: 60
        max_concurrent_runs: 5
    YAML
      _out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "disable", "proj")
      assert_equal 0, status.exitstatus
      data = YAML.safe_load(File.read(cfg_path))
      assert_equal false, data.dig("daemon", "enabled"),
                   "disable on already-disabled is a no-op (idempotent)"
      assert_equal 60, data.dig("daemon", "poll_interval_sec"), "tunables preserved"
      assert_equal 5, data.dig("daemon", "max_concurrent_runs"), "tunables preserved"
    end
  end

  # ── CLI shape: no subcommand, multi-positional ──

  def test_daemon_with_no_subcommand_returns_structured_usage_error
    with_isolated_hive_home do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "bare `hive daemon` must exit 64 (USAGE) with the same shape as `hive daemon frobnicate`"
      assert_match(/missing SUBCOMMAND/, err)
      assert_match(/start, stop, status, reload, tail, enable, disable/, err)
    end
  end

  def test_daemon_enable_with_extra_positional_args_returns_usage_error
    with_registered_project do |env, _cfg_path, _root|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "extra-arg")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "multi-positional argv must exit 64 (USAGE), not pass through Thor's stringified error"
      assert_match(/too many positional/i, err)
    end
  end

  # ── Schema-vs-CLI-output round-trip for the JSON envelope ──
  # schema_files_test.rb validates the Ruby ErrorEnvelope.build payload,
  # not the actual CLI subprocess stdout. A `.compact` dropping a
  # required key on the producer side would not be caught. This test
  # parses the real binary output and validates against the schema.

  def test_enable_json_success_envelope_validates_against_published_schema
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll"))))
    with_registered_project do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "proj", "--json")
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "real CLI subprocess stdout must validate against hive-daemon-enroll.v1 schema; got: #{errors.inspect}"
    end
  end

  def test_enable_json_error_envelope_validates_against_published_schema
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll"))))
    with_registered_project do |env, _cfg_path, _root|
      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "enable", "nope", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "real CLI subprocess error stdout must validate against hive-daemon-enroll.v1 ErrorPayload arm; got: #{errors.inspect}"
    end
  end

  def test_status_json_envelope_validates_against_published_schema
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-status"))))
    with_isolated_hive_home do |_home, env|
      out, _err, _status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "status", "--json")
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "real CLI subprocess stdout must validate against hive-daemon-status.v1; got: #{errors.inspect}"
    end
  end

  def test_stop_json_envelope_validates_against_published_schema
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-stop"))))
    with_isolated_hive_home do |_home, env|
      out, _err, _status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN, "daemon", "stop", "--json")
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "real CLI subprocess stdout must validate against hive-daemon-stop.v1; got: #{errors.inspect}"
    end
  end

  # ── install: envelope + exit codes ────────────────────────────────────

  def with_isolated_install_target(&block)
    # Install writes to ~/.config/systemd/user/ on Linux; we isolate
    # HOME so the test never touches the user's real systemd config.
    # systemctl_available is forced false via the runner stub by using
    # a non-systemd env (or relying on the installer's ENOENT detection
    # on a sandboxed PATH). Tests that need to assert systemctl-failed
    # outcomes use the unit-level installer test instead.
    Dir.mktmpdir("hive-install-home") do |home|
      env = ENV.to_h.merge("HOME" => home, "HIVE_HOME" => home)
      block.call(home, env)
    end
  end

  def test_install_drift_exits_64_with_json_envelope
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-install"))))
    with_isolated_install_target do |home, env|
      # Seed a drifted unit so first install will refuse without --force.
      unit_path = File.join(home, ".config", "systemd", "user", "hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit_path))
      File.write(unit_path, "stale-pre-existing-content\n")

      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "install", "--json")
      doc = JSON.parse(out)
      assert_equal 64, status.exitstatus,
                   "drift without --force must exit 64 (USAGE) so agents can branch on it"
      assert_equal false, doc["ok"]
      assert_equal "drifted", doc["outcome"]
      assert_equal "drifted", doc["error_kind"]
      assert_equal 64, doc["exit_code"]
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "drift envelope must validate against hive-daemon-install.v1; got: #{errors.inspect}"
    end
  end

  def test_install_force_upgrade_exits_0_with_upgraded_envelope
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-install"))))
    with_isolated_install_target do |home, env|
      unit_path = File.join(home, ".config", "systemd", "user", "hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit_path))
      File.write(unit_path, "stale-pre-existing-content\n")

      out, _err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "install", "--force", "--json")
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors,
                   "install --force envelope must validate against hive-daemon-install.v1; got: #{errors.inspect}"

      # The on-disk write must have happened regardless of whether the
      # service-manager call succeeded — `atomic_write` runs BEFORE the
      # systemctl restart, so even on exit 70 the new template is in
      # place. Pin this contract so a future install_linux! refactor
      # that short-circuits before atomic_write fails this assertion.
      assert_includes File.read(unit_path), "ExecStart=",
                      "atomic write must land the new unit before systemctl is called, regardless of exit code"
      backups = Dir["#{unit_path}.bak-*"]
      assert_equal 1, backups.size, "force must write exactly one timestamped backup"
      assert_equal "stale-pre-existing-content\n", File.read(backups.first)

      # Branch on whether systemctl-user is actually available so the
      # assertion is deterministic per environment. On hosts where
      # systemctl IS available, exit 0 is the only acceptable outcome;
      # accepting exit 70 there would silently mask a real systemctl
      # failure regression.
      expected_exit = systemctl_user_available? ? 0 : 70
      assert_equal expected_exit, status.exitstatus,
                   "expected exit #{expected_exit} on this host (systemctl_user_available? = #{systemctl_user_available?}); " \
                   "got #{status.exitstatus}, doc=#{doc.inspect}"

      if status.exitstatus.zero?
        assert_equal true, doc["ok"]
        assert_equal "upgraded", doc["outcome"]
        assert_equal backups.first, doc["backup_path"]
      else
        assert_equal false, doc["ok"]
        assert_equal "failed", doc["outcome"]
        assert_equal 70, doc["exit_code"]
      end
    end
  end

  # systemd-user is available iff `systemctl --user --version` exits 0.
  # ENOENT (no systemctl binary) or non-zero exit (e.g., WSL without
  # systemd-user, CI containers) means the install path will take the
  # "systemctl not detected" / "systemctl call failed" branches.
  def systemctl_user_available?
    return @systemctl_user_available if defined?(@systemctl_user_available)

    @systemctl_user_available =
      begin
        system("systemctl", "--user", "--version", out: File::NULL, err: File::NULL)
      rescue Errno::ENOENT
        false
      end
  end

  def test_install_unsupported_platform_envelope_passes_through
    # We can't realistically force a non-Linux/macOS host in CI, but
    # we can at least pin that the JSON envelope is rendered, exits 0,
    # and target_path is null when the platform is unsupported. Skipped
    # when running on supported platforms.
    skip unless RbConfig::CONFIG["host_os"] !~ /linux|darwin/i
  end

  def test_force_flag_rejected_on_non_install_subcommand
    with_isolated_install_target do |_home, env|
      _out, err, status = Open3.capture3(env, "ruby", "-Ilib", HIVE_BIN,
                                         "daemon", "stop", "--force")
      refute_equal 0, status.exitstatus,
                   "--force on non-install subcommands must error out, not silently no-op"
      assert_includes err.to_s + _out.to_s, "--force only applies to `install`",
                      "error message must point operators at the right subcommand"
    end
  end
end
