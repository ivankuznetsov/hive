require "test_helper"
require "hive/commands/daemon"

class HiveCommandsDaemonTest < Minitest::Test
  include HiveTestHelper

  FakeDispatcher = Struct.new(:calls) do
    def run_forever
      calls << :run_forever
    end
  end

  FakeInstaller = Struct.new(:target_path, :last_backup_path, :last_restart_invoked,
                             :envelope_platform, :messages, keyword_init: true)

  def setup
    @home = Dir.mktmpdir("hive-daemon-command")
  end

  def teardown
    FileUtils.rm_rf(@home) if @home
  end

  def daemon(subcommand, **kwargs)
    Hive::Commands::Daemon.new(subcommand, **{ hive_home: @home }.merge(kwargs))
  end

  def write_pid_payload(pid: 4242, process_start_time: "start-time")
    File.write(
      File.join(@home, ".daemon.pid"),
      {
        "pid" => pid,
        "process_start_time" => process_start_time,
        "started_at" => Time.now.utc.iso8601
      }.to_yaml
    )
  end

  def daemon_config
    {
      "max_concurrent_runs" => 2,
      "max_concurrent_per_project" => 1,
      "max_runs_per_day_per_project" => 3,
      "log_file" => File.join(@home, "logs", "daemon.log"),
      "log_max_bytes" => 1024,
      "log_max_files" => 2,
      "pr_merge_poll_interval_sec" => 5
    }
  end

  def with_replaced_singleton_method(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original) if original
  end

  def test_call_routes_all_non_enrollment_subcommands
    routed = []
    %w[start stop status reload tail install].each do |subcommand|
      command = daemon(subcommand)
      command.define_singleton_method(:start_daemon) { routed << :start }
      command.define_singleton_method(:stop_daemon) { routed << :stop }
      command.define_singleton_method(:status_daemon) { routed << :status }
      command.define_singleton_method(:reload_daemon) { routed << :reload }
      command.define_singleton_method(:tail_daemon) { routed << :tail }
      command.define_singleton_method(:install_daemon) { routed << :install }

      command.call
    end

    assert_equal %i[start stop status reload tail install], routed
  end

  def test_start_daemon_writes_pid_loads_global_config_runs_dispatcher_and_cleans_pid
    command = daemon("start", dry_run: true)
    dispatcher = FakeDispatcher.new([])
    config = daemon_config
    captured = nil

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(pid) { "start-#{pid}" }) do
      with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { config }) do
        with_replaced_singleton_method(Hive::Daemon::Dispatcher, :new, lambda { |**kwargs|
          captured = kwargs
          dispatcher
        }) do
          command.call
        end
      end
    end

    assert_equal [ :run_forever ], dispatcher.calls
    assert_equal({ "daemon" => config }, captured.fetch(:config))
    assert_equal true, captured.fetch(:dry_run)
    refute File.exist?(command.pid_file), "clean shutdown must remove the YAML PID file it wrote"
  end

  def test_start_daemon_refuses_when_own_start_time_is_unavailable
    command = daemon("start")

    error = with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { }) do
      assert_raises(Hive::Error) { command.call }
    end

    assert_match(/cannot read process start time/, error.message)
    refute File.exist?(command.pid_file)
  end

  def test_status_json_reports_running_verified_daemon
    command = daemon("status", json: true)
    write_pid_payload(pid: 1234)
    File.utime(Time.now - 7, Time.now - 7, command.pid_file)
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, pid| pid == 1234 }

    out, _err = capture_io { command.call }

    doc = JSON.parse(out)
    assert_equal true, doc.fetch("running")
    assert_equal 1234, doc.fetch("pid")
    assert_operator doc.fetch("uptime_sec"), :>=, 0
  end

  def test_reload_json_success_sends_hup_and_emits_envelope
    command = daemon("reload", json: true)
    write_pid_payload(pid: 1234)
    signals = []
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :verified }
    command.define_singleton_method(:send_signal_safely) { |pid, signal| signals << [ pid, signal ] }

    out, _err = capture_io { command.call }

    assert_equal [ [ 1234, :HUP ] ], signals
    doc = JSON.parse(out)
    assert_equal true, doc.fetch("ok")
    assert_equal 1234, doc.fetch("pid")
    refute doc.key?("reason")
  end

  def test_reload_text_success_reports_pid
    command = daemon("reload")
    write_pid_payload(pid: 5678)
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :legacy }
    command.define_singleton_method(:send_signal_safely) { |_pid, _signal| true }

    out, _err = capture_io { command.call }

    assert_includes out, "daemon reload requested (pid 5678)"
  end

  def test_stop_json_handles_malformed_and_dead_pid_files
    malformed = daemon("stop", json: true)
    File.write(malformed.pid_file, "not a pid payload")

    out, _err = capture_io { malformed.call }
    doc = JSON.parse(out)
    assert_equal "malformed_pid_file", doc.fetch("reason")
    refute File.exist?(malformed.pid_file)

    dead = daemon("stop", json: true)
    write_pid_payload(pid: 9999)
    dead.define_singleton_method(:pid_alive?) { |_pid| false }

    out, _err = capture_io { dead.call }
    doc = JSON.parse(out)
    assert_equal 9999, doc.fetch("stale_pid")
    refute File.exist?(dead.pid_file)
  end

  def test_stop_sends_term_and_reports_success_when_process_exits
    command = daemon("stop")
    write_pid_payload(pid: 4321)
    alive_results = [ true, true, false, false ]
    signals = []
    command.define_singleton_method(:pid_alive?) { |_pid| alive_results.shift }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :verified }
    command.define_singleton_method(:send_signal_safely) { |pid, signal| signals << [ pid, signal ] }
    command.define_singleton_method(:sleep) { |_seconds| true }

    out, _err = capture_io { command.call }

    assert_equal [ [ 4321, :TERM ] ], signals
    assert_includes out, "daemon stopped (pid 4321)"
  end

  def test_stop_escalates_to_kill_when_process_survives_grace
    command = daemon("stop")
    write_pid_payload(pid: 2468)
    signals = []
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :verified }
    command.define_singleton_method(:send_signal_safely) { |pid, signal| signals << [ pid, signal ] }
    base = Time.utc(2026, 5, 22, 12, 0, 0)
    times = [ base, base + 601 ]

    with_replaced_singleton_method(Time, :now, -> { times.shift || base + 601 }) do
      capture_io { command.call }
    end

    assert_equal [ [ 2468, :TERM ], [ 2468, :KILL ] ], signals
    refute File.exist?(command.pid_file)
  end

  def test_tail_streams_existing_log_until_interrupted
    command = daemon("tail")
    FileUtils.mkdir_p(File.dirname(command.log_file))
    File.write(command.log_file, "")
    sleeps = 0
    command.define_singleton_method(:sleep) do |_seconds|
      sleeps += 1
      if sleeps == 1
        File.open(command.log_file, "a") { |file| file.write("ready\n") }
      else
        raise Interrupt
      end
    end

    out, _err = capture_io { command.call }

    assert_equal "ready\n", out
  end

  def test_emit_install_success_summary_covers_positive_outcomes
    command = daemon("install")
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: "/tmp/hive-daemon.service.bak",
      last_restart_invoked: true,
      envelope_platform: "linux-systemd-user",
      messages: []
    )

    out, _err = capture_io do
      command.send(:emit_install_success_summary, installer, :written)
      command.send(:emit_install_success_summary, installer, :upgraded)
      command.send(:emit_install_success_summary, installer, :unchanged)
      command.send(:emit_install_success_summary, installer, :unsupported)
    end

    assert_includes out, "installed unit"
    assert_includes out, "upgraded unit"
    assert_includes out, "backup: /tmp/hive-daemon.service.bak"
    assert_includes out, "unit already up to date"
  end

  def test_emit_install_outcome_json_drifted_raises_with_error_envelope
    command = daemon("install", json: true)
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux-systemd-user",
      messages: [ "changed locally" ]
    )

    out, _err = capture_io do
      assert_raises(Hive::DaemonInstallDriftError) do
        command.send(:emit_install_outcome, installer, :drifted)
      end
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "drifted", doc.fetch("outcome")
    assert_equal Hive::ExitCodes::USAGE, doc.fetch("exit_code")
  end

  def test_enroll_next_action_reports_reload_only_when_values_changed
    command = daemon("enable")

    reload_action = command.send(:enroll_next_action, [ { "previous" => false } ], true)
    assert_equal "reload", reload_action.fetch("kind")
    assert_equal false, reload_action.fetch("required")

    no_op = command.send(:enroll_next_action, [ { "previous" => true } ], true)
    assert_equal({ "kind" => "no_op", "reason" => "no projects changed" }, no_op)
  end

  def test_write_daemon_block_rejects_missing_and_non_mapping_config
    command = daemon("enable")
    missing = File.join(@home, "missing", "config.yml")

    error = nil
    capture_io do
      error = assert_raises(Hive::Commands::Daemon::UsageError) do
        command.send(:write_daemon_block, missing, true)
      end
    end
    assert_equal Hive::Schemas::EnrollErrorKind::NOT_INITIALISED, error.error_kind

    cfg = File.join(@home, "config.yml")
    File.write(cfg, "daemon: nope\n")
    assert_raises(Hive::ConfigError) { command.send(:write_daemon_block, cfg, true) }
  end

  def test_upsert_daemon_enabled_preserves_comments_and_inserts_missing_keys
    command = daemon("enable")

    replaced = command.send(:upsert_daemon_enabled, "daemon:\n  enabled: false # keep\n  poll: 30\n", true)
    assert_equal "daemon:\n  enabled: true # keep\n  poll: 30\n", replaced

    inserted = command.send(:upsert_daemon_enabled, "daemon:\n  poll: 30\n", false)
    assert_equal "daemon:\n  enabled: false\n  poll: 30\n", inserted

    appended = command.send(:upsert_daemon_enabled, "default_branch: main\n", true)
    assert_equal "default_branch: main\n\ndaemon:\n  enabled: true\n", appended
  end

  def test_pid_helpers_cover_legacy_reused_unverified_and_payload_shapes
    command = daemon("status")
    assert_equal :unverified, command.send(:pid_ownership, nil, 1)
    assert_equal :legacy, command.send(:pid_ownership, { "_legacy" => true }, 1)

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "live" }) do
      assert_equal :verified, command.send(:pid_ownership, { "process_start_time" => "live" }, 1)
      assert_equal :reused, command.send(:pid_ownership, { "process_start_time" => "old" }, 1)
    end

    File.write(command.pid_file, "123\n")
    assert_equal({ "pid" => 123, "process_start_time" => nil, "_legacy" => true }, command.send(:read_pid_file_payload))

    File.write(command.pid_file, "not yaml")
    assert_nil command.send(:read_pid_file_payload)

    payload = command.send(:pid_file_payload, 456, "supplied")
    assert_equal 456, payload.fetch("pid")
    assert_equal "supplied", payload.fetch("process_start_time")
  end

  def test_read_live_pid_requires_alive_pid_owned_by_this_daemon
    command = daemon("status")
    write_pid_payload(pid: 1234)
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, _pid| false }

    assert_nil command.send(:read_live_pid)
  end

  def test_send_signal_safely_ignores_esrch_and_warns_on_eperm
    command = daemon("stop")

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      capture_io { command.send(:send_signal_safely, 123, :TERM) }
    end

    _out, err = with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      capture_io { command.send(:send_signal_safely, 123, :TERM) }
    end
    assert_match(/insufficient permissions/, err)
  end
end
