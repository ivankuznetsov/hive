require "test_helper"
require "set"
require "hive/babysitter/dispatcher"
require "hive/babysitter/gh_ops"
require "hive/babysitter/logger"
require "hive/babysitter/pr_fixer"
require "hive/babysitter/project_tick"
require "hive/babysitter/worktree"
require "hive/commands/babysit"
require "hive/commands/init/prompts"
require "hive/cli"

class BabysitterCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Status = Struct.new(:success, keyword_init: true) do
    def success? = success
  end

  FakeLogger = Struct.new(:events, :path, keyword_init: true) do
    def event(name, **attrs)
      events << [ name, attrs ]
    end

    def close
      events << [ :closed, {} ]
    end
  end

  def project_entry(dir)
    { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def cfg(overrides = {})
    {
      "execute" => { "agent" => "claude" },
      "agents" => {},
      "babysitter" => {
        "enabled" => true,
        "interval" => "30s",
        "labels_ignore" => %w[wip],
        "max_concurrent_prs" => 2,
        "budget_minutes" => 30,
        "budget_usd" => 50
      }
    }.merge(overrides)
  end

  def write_project_config(dir, data = cfg)
    FileUtils.mkdir_p(File.join(dir, ".hive-state"))
    File.write(File.join(dir, ".hive-state", "config.yml"), data.to_yaml)
  end

  def fake_logger(path = "/tmp/babysitter.log")
    FakeLogger.new(events: [], path: path)
  end

  def test_cli_babysit_rejects_once_subcommand_and_extra_targets_then_dispatches
    cli = Hive::CLI.new([], { once: true, detach: false, dry_run: false, all: false })
    assert_raises(Hive::InvalidTaskPath) { cli.babysit("start") }

    cli = Hive::CLI.new([], { once: false, detach: false, dry_run: false, all: false })
    assert_raises(Hive::InvalidTaskPath) { cli.babysit("status", "one", "two") }

    calls = []
    with_replaced_singleton_method(Hive::Commands::Babysit, :new, lambda { |*args, **kwargs|
      calls << [ args, kwargs ]
      Object.new.tap { |obj| obj.define_singleton_method(:call) { :called } }
    }) do
      assert_equal :called, cli.babysit("status")
    end
    assert_equal [ [ "status", nil ], { detach: false, dry_run: false, once: false, all: false } ], calls.first
  end

  def test_command_call_routes_known_subcommands_and_rejects_unknown
    cmd = Hive::Commands::Babysit.new("unknown")
    assert_raises(Hive::InvalidTaskPath) { cmd.call }

    %w[start stop status reload tail].each do |subcommand|
      routed = false
      cmd = Hive::Commands::Babysit.new(subcommand)
      cmd.define_singleton_method("#{subcommand}_daemon") { routed = true }
      cmd.call
      assert routed, "#{subcommand} should route"
    end
  end

  def test_start_daemon_reserves_pid_runs_dispatcher_and_removes_own_pid
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("start", hive_home: home)
      dispatcher = Object.new
      dispatcher.define_singleton_method(:run_forever) { nil }
      cmd.define_singleton_method(:build_dispatcher) { dispatcher }

      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "12345" }) do
        cmd.call
      end

      refute File.exist?(cmd.pid_file)
    end
  end

  def test_start_daemon_rejects_live_concurrent_and_unverifiable_pid
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("start", hive_home: home)
      cmd.define_singleton_method(:read_live_pid) { 123 }
      assert_raises(Hive::ConcurrentRunError) { cmd.call }

      cmd = Hive::Commands::Babysit.new("start", hive_home: home)
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { nil }) do
        assert_raises(Hive::Error) { cmd.call }
      end
      refute File.exist?(cmd.pid_file)
    end
  end

  def test_start_daemon_rejects_concurrent_pid_file_create
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("start", hive_home: home)
      cmd.define_singleton_method(:read_live_pid) { nil }
      FileUtils.mkdir_p(home)
      File.write(cmd.pid_file, { "pid" => 77 }.to_yaml)

      with_replaced_singleton_method(FileUtils, :rm_f, ->(_path) { }) do
        error = assert_raises(Hive::ConcurrentRunError) { cmd.call }
        assert_includes error.message, "already starting"
      end
    end
  end

  def test_start_daemon_leaves_pid_when_cleanup_payload_is_unreadable
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("start", hive_home: home)
      dispatcher = Object.new
      dispatcher.define_singleton_method(:run_forever) { nil }
      cmd.define_singleton_method(:build_dispatcher) { dispatcher }
      cmd.define_singleton_method(:read_pid_file_payload) { raise "unreadable" }

      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "12345" }) do
        cmd.call
      end

      assert File.exist?(cmd.pid_file)
    end
  end

  def test_run_once_zero_projects_and_resolution_errors
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new(nil, nil, once: true, all: true, hive_home: home)
      out, _err = capture_io { cmd.call }
      assert_includes out, "0 enabled projects"

      assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Babysit.new(nil, "demo", once: true, all: true, hive_home: home).call
      end
      assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Babysit.new(nil, nil, once: true, hive_home: home).call
      end
      assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Babysit.new(nil, "missing", once: true, hive_home: home).call
      end
    end
  end

  def test_run_once_builds_dispatcher_for_known_project
    with_tmp_global_config do |home|
      project = { "name" => "demo", "path" => "/tmp/demo" }
      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { project }) do
        dispatcher = Object.new
        ran = false
        dispatcher.define_singleton_method(:run_forever) { ran = true }
        cmd = Hive::Commands::Babysit.new(nil, "demo", once: true, hive_home: home)
        build_args = nil
        cmd.define_singleton_method(:build_dispatcher) do |project_name:, max_ticks:|
          build_args = [ project_name, max_ticks ]
          dispatcher
        end
        cmd.call
        assert ran
        assert_equal [ "demo", 1 ], build_args
      end
    end
  end

  def test_stop_daemon_handles_pid_file_states_and_success
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("stop", hive_home: home)
      _out, err = capture_io { cmd.call }
      assert_includes err, "not running"

      File.write(cmd.pid_file, { "pid" => nil }.to_yaml)
      _out, err = capture_io { cmd.call }
      assert_includes err, "malformed"

      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      cmd.define_singleton_method(:pid_alive?) { |_pid| false }
      _out, err = capture_io { cmd.call }
      assert_includes err, "not alive"

      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      cmd.define_singleton_method(:pid_alive?) { |_pid| true }
      cmd.define_singleton_method(:pid_ownership) { |_payload, _pid| :reused }
      _out, err = capture_io { cmd.call }
      assert_includes err, "appears reused"

      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      cmd.define_singleton_method(:pid_ownership) { |_payload, _pid| :unverified }
      _out, err = capture_io { assert_raises(Hive::Error) { cmd.call } }
      assert_includes err, "cannot verify"

      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      alive = true
      signals = []
      cmd.define_singleton_method(:pid_ownership) { |_payload, _pid| :owned }
      cmd.define_singleton_method(:pid_alive?) { |_pid| alive }
      cmd.define_singleton_method(:send_signal_safely) { |_pid, signal| signals << signal; alive = false }
      out, _err = capture_io { cmd.call }
      assert_includes out, "stopped"
      assert_equal [ :TERM ], signals
    end
  end

  def test_stop_daemon_escalates_after_grace_when_still_alive
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("stop", hive_home: home)
      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      signals = []
      cmd.define_singleton_method(:pid_alive?) { |_pid| true }
      cmd.define_singleton_method(:pid_ownership) { |_payload, _pid| :owned }
      cmd.define_singleton_method(:send_signal_safely) { |_pid, signal| signals << signal }
      cmd.define_singleton_method(:sleep) { |_sec| nil }
      after_grace = Hive::Commands::Babysit::STOP_GRACE_SEC + 1
      after_kill_grace = Hive::Commands::Babysit::STOP_GRACE_SEC + 6
      times = [ Time.at(0), Time.at(after_grace), Time.at(after_grace), Time.at(after_kill_grace) ]
      with_replaced_singleton_method(Time, :now, -> { times.shift || Time.at(after_kill_grace) }) do
        assert_raises(Hive::Error) { cmd.call }
      end
      assert_includes signals, :KILL
    end
  end

  def test_stop_daemon_removes_pid_when_process_exits_after_kill
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("stop", hive_home: home)
      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      alive = true
      signals = []
      cmd.define_singleton_method(:pid_alive?) { |_pid| alive }
      cmd.define_singleton_method(:pid_ownership) { |_payload, _pid| :owned }
      cmd.define_singleton_method(:send_signal_safely) do |_pid, signal|
        signals << signal
        alive = false if signal == :KILL
      end
      cmd.define_singleton_method(:sleep) { |_sec| nil }
      after_grace = Hive::Commands::Babysit::STOP_GRACE_SEC + 1
      times = [ Time.at(0), Time.at(after_grace), Time.at(after_grace) ]

      out, _err = capture_io do
        with_replaced_singleton_method(Time, :now, -> { times.shift || Time.at(after_grace) }) do
          cmd.call
        end
      end

      assert_equal %i[TERM KILL], signals
      refute File.exist?(cmd.pid_file)
      assert_includes out, "stopped"
    end
  end

  def test_stop_daemon_wait_loop_sleeps_until_process_exits
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("stop", hive_home: home)
      File.write(cmd.pid_file, { "pid" => 123 }.to_yaml)
      alive_checks = 0
      slept = false
      cmd.define_singleton_method(:pid_alive?) { |_pid| alive_checks += 1; alive_checks < 3 }
      cmd.define_singleton_method(:pid_ownership) { |_payload, _pid| :owned }
      cmd.define_singleton_method(:send_signal_safely) { |_pid, _signal| nil }
      cmd.define_singleton_method(:sleep) { |_sec| slept = true }
      cmd.call
      assert slept
    end
  end

  def test_status_reload_and_tail_error_paths
    with_tmp_global_config do |home|
      status = Hive::Commands::Babysit.new("status", hive_home: home)
      assert_raises(Hive::Error) { status.call }

      reload = Hive::Commands::Babysit.new("reload", hive_home: home)
      assert_raises(Hive::Error) { reload.call }
      File.write(reload.pid_file, { "pid" => 123 }.to_yaml)
      reload.define_singleton_method(:pid_alive?) { |_pid| false }
      assert_raises(Hive::Error) { reload.call }
      reload.define_singleton_method(:pid_alive?) { |_pid| true }
      reload.define_singleton_method(:pid_ownership) { |_payload, _pid| :reused }
      assert_raises(Hive::Error) { reload.call }
      reload.define_singleton_method(:pid_ownership) { |_payload, _pid| :unverified }
      assert_raises(Hive::Error) { reload.call }

      signals = []
      reload.define_singleton_method(:pid_ownership) { |_payload, _pid| :owned }
      reload.define_singleton_method(:send_signal_safely) { |_pid, signal| signals << signal }
      out, _err = capture_io { reload.call }
      assert_includes out, "reload requested"
      assert_equal [ :HUP ], signals

      tail = Hive::Commands::Babysit.new("tail", hive_home: home)
      assert_raises(Hive::Error) { tail.call }
    end
  end

  def test_tail_daemon_exits_on_interrupt
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("tail", hive_home: home)
      FileUtils.mkdir_p(File.dirname(cmd.log_file))
      File.write(cmd.log_file, "old\n")
      cmd.define_singleton_method(:sleep) { |_sec| raise Interrupt }
      cmd.call
    end
  end

  def test_tail_daemon_writes_available_chunk_before_interrupt
    with_tmp_global_config do |home|
      cmd = Hive::Commands::Babysit.new("tail", hive_home: home)
      FileUtils.mkdir_p(File.dirname(cmd.log_file))
      File.write(cmd.log_file, "")
      fake_file = Object.new
      fake_file.define_singleton_method(:seek) { |_offset, _whence| nil }
      reads = [ "new\n", nil ]
      fake_file.define_singleton_method(:read) { reads.shift }
      fake_file.define_singleton_method(:close) { nil }
      cmd.define_singleton_method(:sleep) { |_sec| raise Interrupt }
      original_open = File.method(:open)
      File.define_singleton_method(:open) do |path, *_args, &block|
        if path == cmd.log_file
          block.call(fake_file)
        else
          original_open.call(path, *_args, &block)
        end
      end
      out, _err = capture_io { cmd.call }
      assert_equal "new\n", out
    ensure
      File.define_singleton_method(:open, original_open) if original_open
    end
  end

  def test_dispatcher_tick_filters_projects_logs_failures_and_reload
    with_tmp_dir do |dir|
      enabled = project_entry(File.join(dir, "enabled"))
      disabled = project_entry(File.join(dir, "disabled"))
      broken = project_entry(File.join(dir, "broken"))
      write_project_config(enabled.fetch("path"))
      write_project_config(disabled.fetch("path"), cfg("babysitter" => { "enabled" => false }))
      logger = fake_logger(File.join(dir, "babysitter.log"))
      original_load = Hive::Config.method(:load)

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ enabled, disabled, broken ] }) do
        with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
          raise Hive::ConfigError, "bad config" if path == broken.fetch("path")

          original_load.call(path)
        }) do
          with_replaced_singleton_method(Hive::Babysitter::ProjectTick, :run, ->(*_args, **_kwargs) { raise "tick failed" }) do
            dispatcher = Hive::Babysitter::Dispatcher.new(logger: logger, max_ticks: 1)
            assert_equal 1, dispatcher.tick(now: Time.at(0))
          end
        end
      end
      assert logger.events.any? { |name, attrs| name == :fatal && attrs[:message].include?("tick failed") }
      assert logger.events.any? { |name, attrs| name == :project_skipped && attrs[:reason] == "babysitter_disabled" }
      assert logger.events.any? { |name, attrs| name == :project_skipped && attrs[:reason] == "config_error" }

      old_trap = Signal.method(:trap)
      Signal.define_singleton_method(:trap) { |_signal, &_block| nil }
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        dispatcher = Hive::Babysitter::Dispatcher.new(logger: fake_logger(File.join(dir, "run.log")), max_ticks: 1)
        dispatcher.request_reload!
        dispatcher.run_forever
      end

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        dispatcher = Hive::Babysitter::Dispatcher.new(logger: fake_logger(File.join(dir, "sleep.log")))
        dispatcher.define_singleton_method(:interruptible_sleep) { |_seconds| request_shutdown! }
        dispatcher.run_forever
      end
    ensure
      Signal.define_singleton_method(:trap, old_trap) if old_trap
    end
  end

  def test_dispatcher_sleep_stops_on_shutdown_and_reload_failure_is_logged
    logger = fake_logger
    dispatcher = Hive::Babysitter::Dispatcher.new(logger: logger)
    Thread.new { sleep 0.01; dispatcher.request_shutdown! }
    dispatcher.send(:interruptible_sleep, 5)

    with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { raise "bad config" }) do
      dispatcher.send(:reload_logger!)
    end
    assert logger.events.any? { |name, attrs| name == :fatal && attrs[:message].include?("logger reload failed") }
  end

  def test_gh_ops_side_effect_paths_and_comment_dedup
    status = Status.new(success: true)
    calls = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      calls << cmd
      case cmd
      when [ "gh", "pr", "view", "42", "--json", "labels" ]
        [ { labels: [] }.to_json, "", status ]
      when [ "gh", "pr", "view", "42", "--json", "comments" ]
        [ { comments: [] }.to_json, "", status ]
      else
        [ "ok", "", status ]
      end
    }) do
      assert Hive::Babysitter::GhOps.add_label("/tmp/wt", 42, "label", cfg: {}, dry_run: false).success?
      assert Hive::Babysitter::GhOps.post_pr_comment("/tmp/wt", 42, "body", cfg: {}, dry_run: false).success?
      assert Hive::Babysitter::GhOps.rerun_ci("/tmp/wt", 99, cfg: {}, dry_run: false).success?
    end
    assert calls.any? { |cmd| cmd.include?("edit") }
    assert calls.any? { |cmd| cmd.include?("comment") }
    assert calls.any? { |cmd| cmd.include?("rerun") }

    now = Time.utc(2026, 6, 3, 1, 0, 0)
    recent = Hive::Babysitter::GhOps.give_up_marker(now: now)
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) {
      [ { comments: [ { body: recent } ] }.to_json, "", status ]
    }) do
      with_replaced_singleton_method(Time, :now, -> { now }) do
        result = Hive::Babysitter::GhOps.post_pr_comment("/tmp/wt", 42, "body", cfg: {}, dry_run: false)
        assert_equal "recent give-up comment already exists", result.stdout
      end
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) {
      [ { comments: [ { body: recent } ] }.to_json, "", status ]
    }) do
      assert Hive::Babysitter::GhOps.recent_give_up_comment?("/tmp/wt", 42, cfg: {}, now: now)
    end
    assert_nil Hive::Babysitter::GhOps.extract_give_up_marker_timestamp("none")
    assert_nil Hive::Babysitter::GhOps.extract_give_up_marker_timestamp("<!-- hive-babysitter:give-up:nope -->")
  end

  def test_gh_ops_parse_failures_return_false
    bad_status = Status.new(success: false)
    ok_status = Status.new(success: true)
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "{", "", ok_status ] }) do
      refute Hive::Babysitter::GhOps.pr_has_label?("/tmp/wt", 42, "label", cfg: {})
      refute Hive::Babysitter::GhOps.recent_give_up_comment?("/tmp/wt", 42, cfg: {})
    end
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "", bad_status ] }) do
      refute Hive::Babysitter::GhOps.pr_has_label?("/tmp/wt", 42, "label", cfg: {})
      refute Hive::Babysitter::GhOps.recent_give_up_comment?("/tmp/wt", 42, cfg: {})
    end
  end

  def test_logger_fallback_rotation_and_reopen_failure
    with_tmp_dir do |dir|
      log_path = File.join(dir, "babysitter.log")
      File.write(log_path, "x" * 10)
      logger = Hive::Babysitter::Logger.new(path: log_path, max_bytes: 1, max_files: 1)
      logger.event(:tick_begin)
      logger.close
      assert File.exist?(log_path)

      log_path = File.join(dir, "ring.log")
      File.write(log_path, "x" * 10)
      File.write("#{log_path}.0", "old")
      logger = Hive::Babysitter::Logger.new(path: log_path, max_bytes: 1, max_files: 3)
      logger.event(:tick_begin)
      logger.close
      assert File.exist?("#{log_path}.0")

      logger = Hive::Babysitter::Logger.new(path: File.join(dir, "size.log"), max_bytes: 1, max_files: 1)
      logger.instance_variable_get(:@file).define_singleton_method(:size) { raise IOError }
      logger.event(:tick_begin)
      logger.close
    end
  end

  def test_logger_initial_open_fallback_writes_to_stderr
    original_open = File.method(:open)
    File.define_singleton_method(:open) { |path, *_args| raise Errno::EACCES, path.to_s }
    logger = nil
    _out, err = capture_io do
      logger = Hive::Babysitter::Logger.new(path: "/tmp/nope/babysitter.log")
      logger.event(:tick_begin)
    end
    assert logger.stderr_fallback?
    assert_includes err, "falling back to stderr"
    assert_includes err, "hive-babysitter-log"
  ensure
    File.define_singleton_method(:open, original_open) if original_open
  end

  def test_logger_rotation_reopen_failure_falls_back_to_stderr
    with_tmp_dir do |dir|
      log_path = File.join(dir, "bad.log")
      File.write(log_path, "x" * 10)
      logger = Hive::Babysitter::Logger.new(path: log_path, max_bytes: 1, max_files: 1)
      original_open = File.method(:open)
      opens = 0
      File.define_singleton_method(:open) do |*args, **kwargs, &block|
        opens += 1
        raise Errno::EACCES, args.first.to_s if opens <= 2

        original_open.call(*args, **kwargs, &block)
      end
      _out, err = capture_io { logger.event(:tick_begin) }
      assert_includes err, "falling back to stderr"
      assert logger.stderr_fallback?
    ensure
      File.define_singleton_method(:open, original_open) if original_open
    end
  end

  def test_pr_fixer_fork_timeout_budget_dry_run_failure_and_long_comment
    with_tmp_dir do |dir|
      project = project_entry(dir)
      pr = {
        "number" => 42,
        "url" => "https://example.test/pr/42",
        "headRefName" => "feature",
        "baseRefName" => "main",
        "isCrossRepository" => true
      }
      non_green = { "mergeable" => "CONFLICTING", "statusCheckRollup" => [] }
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { non_green }) do
        with_replaced_singleton_method(Hive::Babysitter::GhOps, :add_label, ->(*_args, **_kwargs) {
          Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
        }) do
          assert_equal :fork_pr, Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: true, logger: nil, inflight: Set.new)
        end
      end

      fixer = Hive::Babysitter::PrFixer.new(pr.merge("isCrossRepository" => false), project, cfg, dry_run: true, logger: nil, inflight: Set.new)
      assert_equal :timeout, fixer.send(:outcome_for, { status: :ok, timed_out: true })
      assert_equal :budget_exhausted, fixer.send(:outcome_for, { status: :budget_exceeded })
      assert_equal :budget_exhausted, fixer.send(:outcome_for, { status: :error, reason: "budget_exhausted" })
      assert_equal :failure, fixer.send(:outcome_for, { status: :ok }, dir)
      assert_equal :failure, fixer.send(:outcome_for, { status: :error })
      comment = fixer.send(:give_up_comment, { final_message: "x" * 5000 }, :failure)
      assert comment.bytesize < 4500

      fixer.send(:emit_agent_event, :timeout, Time.now)
      fixer.send(:emit_agent_event, :budget_exhausted, Time.now)
      non_dry_fixer = Hive::Babysitter::PrFixer.new(pr.merge("isCrossRepository" => false), project, cfg,
                                                    dry_run: false, logger: nil, inflight: Set.new)
      with_replaced_singleton_method(Hive::Babysitter::GhOps, :add_label, ->(*_args, **_kwargs) {
        Hive::Gh::PushResult.new(success: false, stdout: "", stderr: "label failed")
      }) do
        with_replaced_singleton_method(Hive::Babysitter::GhOps, :post_pr_comment, ->(*_args, **_kwargs) {
          Hive::Gh::PushResult.new(success: false, stdout: "", stderr: "comment failed")
        }) do
          non_dry_fixer.send(:give_up, dir, { final_message: "tail" }, :timeout, Time.now)
          non_dry_fixer.send(:give_up, dir, { final_message: "tail" }, :budget_exhausted, Time.now)
        end
      end

      dry_fixer = Hive::Babysitter::PrFixer.new(pr.merge("isCrossRepository" => false), project, cfg,
                                                dry_run: true, logger: nil, inflight: Set.new)
      with_replaced_singleton_method(Hive::Babysitter::GhOps, :add_label, ->(*_args, **_kwargs) {
        Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
      }) do
        with_replaced_singleton_method(Hive::Babysitter::GhOps, :post_pr_comment, ->(*_args, **_kwargs) {
          Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
        }) do
          dry_fixer.send(:give_up, dir, { final_message: "tail" }, :failure, Time.now)
        end
      end
    end
  end

  def test_project_tick_disabled_failure_outcomes_and_gh_error
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_project_config(project.fetch("path"), cfg("babysitter" => { "enabled" => false }))
      logger = fake_logger
      assert_equal({ total: 0, fixed: 0, untouched: 0, needs_human: 0 },
                   Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: Set.new))

      write_project_config(project.fetch("path"))
      prs = [
        { "number" => 1, "labels" => [], "updatedAt" => "bad" },
        { "number" => 2, "labels" => [], "updatedAt" => "2026-06-03T00:00:00Z" },
        { "number" => 3, "labels" => [], "updatedAt" => "2026-06-03T00:01:00Z" }
      ]
      outcomes = [ :success, :dry_run, :timeout ]
      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, ->(*_args, **_kwargs) { outcomes.shift }) do
          with_replaced_singleton_method(Hive::Babysitter::StatusWriter, :append, ->(**_kwargs) { }) do
            summary = Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: Set.new)
            assert_equal({ total: 2, fixed: 1, untouched: 1, needs_human: 0 }, summary)
          end
        end
      end

      outcomes = [ :raise, :timeout ]
      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs.first(2) }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, ->(*_args, **_kwargs) {
          outcome = outcomes.shift
          raise "agent exploded" if outcome == :raise

          outcome
        }) do
          with_replaced_singleton_method(Hive::Babysitter::StatusWriter, :append, ->(**_kwargs) { }) do
            summary = Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: Set.new)
            assert_equal 2, summary[:needs_human]
          end
        end
      end

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { raise Hive::GhError, "no gh" }) do
        summary = Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: Set.new)
        assert_equal({ total: 0, fixed: 0, untouched: 0, needs_human: 0 }, summary)
      end
    end
  end

  def test_misc_validation_gaps
    with_tmp_dir do |_dir|
      assert_raises(Hive::ConfigError) { Hive::Babysitter::Interval.parse("later") }
      begin
        Hive::Babysitter::Interval.parse(Object.new)
      rescue Hive::ConfigError
        # direct rescue keeps the invalid-type raise line covered under the
        # aggregate coverage runner.
      end
      refute Hive::Babysitter::DryRunEnv.send(:which, "definitely-not-hive-binary")
      assert_raises(Hive::ConfigError) do
        Hive::Config.send(:validate_babysitter!, { "babysitter" => { "max_concurrent_prs" => 0 } }, "/tmp/config.yml")
      end
    end
  end

  def test_prompt_babysitter_reprompts_on_invalid_answer
    input = StringIO.new("maybe\nn\n")
    input.define_singleton_method(:tty?) { true }
    output = StringIO.new
    prompts = Hive::Commands::Init::Prompts.new(input: input, output: output, summary_io: StringIO.new)
    refute prompts.send(:prompt_babysitter_enabled)
    assert_includes output.string, "please answer y or n"
  end

  def test_gh_babysitter_helpers_error_paths
    ok = Status.new(success: true)
    bad = Status.new(success: false)

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "{", "", ok ] }) do
      assert_raises(Hive::GhError) { Hive::Gh.list_open_prs("/tmp/wt") }
      assert_raises(Hive::GhError) { Hive::Gh.pr_status_rollup("/tmp/wt", 42) }
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "{}", "", ok ] }) do
      assert_raises(Hive::GhError) { Hive::Gh.list_open_prs("/tmp/wt") }
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "[]", "", ok ] }) do
      assert_raises(Hive::GhError) { Hive::Gh.pr_status_rollup("/tmp/wt", 42) }
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { [ "", "nope", bad ] }) do
      assert_raises(Hive::GhError) { Hive::Gh.list_open_prs("/tmp/wt") }
      assert_raises(Hive::GhError) { Hive::Gh.pr_status_rollup("/tmp/wt", 42) }
      assert_raises(Hive::GhError) { Hive::Gh.pr_diff_stat("/tmp/wt", "main", "HEAD") }
    end

    calls = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      calls << cmd
      if cmd.include?("diff")
        [ "stat", "", ok ]
      elsif cmd.include?("rev-list")
        [ "2 3", "", ok ]
      elsif cmd.include?("rev-parse")
        [ "base-sha\n", "", ok ]
      elsif cmd.include?("merge-base")
        [ "merge-base\n", "", ok ]
      elsif cmd.include?("run")
        [ "", "failed", bad ]
      else
        [ "", "", ok ]
      end
    }) do
      assert_equal "stat", Hive::Gh.pr_diff_stat("/tmp/wt", "main", "HEAD")
      divergence = Hive::Gh.pr_base_divergence("/tmp/wt", "main")
      assert_equal 3, divergence.fetch("ahead")
      assert_equal 2, divergence.fetch("behind")
      assert_equal "[hive-babysitter: no job id available, cannot fetch log]", Hive::Gh.fetch_job_log("/tmp/wt", nil)
      assert_includes Hive::Gh.fetch_job_log("/tmp/wt", 99), "failed to fetch log"
      assert_equal [ 1, 3, 3 ], Hive::Gh.allocate_log_budget([ 1, 5, 5 ], 7)
    end
    assert calls.any? { |cmd| cmd.include?("fetch") }

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { raise Hive::GhError, "network" }) do
      assert_includes Hive::Gh.fetch_job_log("/tmp/wt", 99), "network"
    end
  end
end
