require "test_helper"
require "hive/commands/daemon"

class HiveCommandsDaemonTest < Minitest::Test
  include HiveTestHelper

  FakeDispatcher = Struct.new(:calls, :reexec_requested) do
    def initialize(calls, reexec_requested = false)
      super
    end

    def run_forever
      calls << :run_forever
    end

    def reexec_requested?
      reexec_requested
    end
  end

  FakeInstaller = Struct.new(:target_path, :last_backup_path, :last_restart_invoked,
                             :envelope_platform, :messages, keyword_init: true)

  # install! now returns a ServiceInstaller::Outcome (carrying the kind plus
  # backup_path/restarted), so the emit_* helpers and install! stubs are
  # driven with real Outcome objects rather than bare symbols.
  def fake_outcome(kind, backup_path: nil, restarted: false)
    require "hive/commands/service_installer/outcome"
    Hive::Commands::ServiceInstaller::Outcome.new(kind, backup_path: backup_path, restarted: restarted)
  end

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

  def test_start_daemon_invokes_reexec_when_dispatcher_signals_drift
    command = daemon("start", dry_run: true)
    dispatcher = FakeDispatcher.new([], true) # signals drift
    config = daemon_config
    reexec_invoked = false
    command.define_singleton_method(:reexec_with_fresh_code!) { reexec_invoked = true }

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(pid) { "start-#{pid}" }) do
      with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { config }) do
        with_replaced_singleton_method(Hive::Daemon::Dispatcher, :new, ->(**_) { dispatcher }) do
          command.call
        end
      end
    end

    assert reexec_invoked,
           "dispatcher.reexec_requested? true must route through reexec_with_fresh_code!"
    refute File.exist?(command.pid_file),
           "the ensure block must still delete the PID file before the re-exec call"
  end

  def test_reexec_with_fresh_code_calls_kernel_exec_with_daemon_start_argv
    command = daemon("start", dry_run: true)
    captured_argv = nil
    fake_method = ->(*args) { captured_argv = args; raise "exec replaced" }

    # Replace Kernel.method(:exec).call with a recorder that raises so
    # we don't actually exec the test runner away. The raise keeps us
    # in the rescue path of the caller (the test) rather than letting
    # control return into ruby and continue.
    with_replaced_singleton_method(Kernel, :exec, fake_method) do
      assert_raises(RuntimeError) { command.send(:reexec_with_fresh_code!) }
    end

    refute_nil captured_argv, "Kernel.exec stub must have been called"
    assert_equal Process.argv0, captured_argv.first
    assert_includes captured_argv, "daemon"
    assert_includes captured_argv, "start"
    assert_includes captured_argv, "--dry-run",
                    "--dry-run must be forwarded so the re-exec'd process mirrors the current run mode"
  end

  def test_reexec_with_fresh_code_omits_dry_run_when_not_a_dry_run
    command = daemon("start", dry_run: false)
    captured_argv = nil
    fake_method = ->(*args) { captured_argv = args; raise "exec replaced" }

    with_replaced_singleton_method(Kernel, :exec, fake_method) do
      assert_raises(RuntimeError) { command.send(:reexec_with_fresh_code!) }
    end

    refute_includes captured_argv, "--dry-run",
                    "non-dry-run daemons must re-exec without --dry-run"
  end


  def test_start_daemon_refuses_when_pid_file_points_to_live_daemon
    command = daemon("start")
    command.define_singleton_method(:read_live_pid) { 2222 }

    error = assert_raises(Hive::ConcurrentRunError) { command.call }

    assert_match(/already running/, error.message)
    assert_equal 2222, error.holder.fetch(:pid)
  end

  def test_start_daemon_detaches_when_requested
    command = daemon("start", detach: true, dry_run: true)
    dispatcher = FakeDispatcher.new([])
    config = daemon_config
    daemon_calls = []

    with_replaced_singleton_method(Process, :daemon, lambda { |nochdir, noclose|
      daemon_calls << [ nochdir, noclose ]
    }) do
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(pid) { "start-#{pid}" }) do
        with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { config }) do
          with_replaced_singleton_method(Hive::Daemon::Dispatcher, :new, ->(**_kwargs) { dispatcher }) do
            command.call
          end
        end
      end
    end

    assert_equal [ [ true, true ] ], daemon_calls
    assert_equal [ :run_forever ], dispatcher.calls
  end

  def test_start_daemon_ignores_pid_payload_cleanup_failures
    command = daemon("start", dry_run: true)
    dispatcher = FakeDispatcher.new([])
    config = daemon_config
    command.define_singleton_method(:read_pid_file_payload) { raise RuntimeError, "bad pid file" }

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(pid) { "start-#{pid}" }) do
      with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { config }) do
        with_replaced_singleton_method(Hive::Daemon::Dispatcher, :new, ->(**_kwargs) { dispatcher }) do
          command.call
        end
      end
    end

    assert_equal [ :run_forever ], dispatcher.calls
    assert File.exist?(command.pid_file), "cleanup failure is swallowed and leaves pid file for manual recovery"
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


  def test_status_json_merges_service_state_fields
    command = daemon("status", json: true)
    write_pid_payload(pid: 1234)
    File.utime(Time.now - 7, Time.now - 7, command.pid_file)
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, pid| pid == 1234 }
    # Inject a fake installer so the merged service-state fields are
    # deterministic and we exercise the merge, not the host's systemd.
    state = {
      "platform" => "linux",
      "unit_path" => "/home/u/.config/systemd/user/hive-daemon.service",
      "service_installed" => true,
      "service_enabled" => true
    }
    fake = Struct.new(:state) do
      def service_state = state
    end.new(state)
    require "hive/commands/daemon/service_installer"
    out, _err = with_replaced_singleton_method(
      Hive::Commands::Daemon::ServiceInstaller, :new, ->(**_kwargs) { fake }
    ) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_equal "hive-daemon-status", doc.fetch("schema")
    assert_equal true, doc.fetch("service_installed")
    assert_equal true, doc.fetch("service_enabled")
    assert_equal "/home/u/.config/systemd/user/hive-daemon.service", doc.fetch("unit_path")
    # Existing fields must survive the merge.
    assert_equal true, doc.fetch("running")
    assert_equal 1234, doc.fetch("pid")

    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-status"))))
    assert_empty schema.validate(doc).map { |error| error["error"] }
  end

  def test_status_json_degrades_service_fields_to_null_when_probe_raises
    command = daemon("status", json: true)
    write_pid_payload(pid: 1234)
    File.utime(Time.now - 7, Time.now - 7, command.pid_file)
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, pid| pid == 1234 }
    fake = Object.new
    fake.define_singleton_method(:service_state) { raise "probe blew up" }
    require "hive/commands/daemon/service_installer"
    out, _err = with_replaced_singleton_method(
      Hive::Commands::Daemon::ServiceInstaller, :new, ->(**_kwargs) { fake }
    ) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_nil doc.fetch("service_installed")
    assert_nil doc.fetch("service_enabled")
    assert_nil doc.fetch("unit_path")
    assert_equal true, doc.fetch("running")

    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-status"))))
    assert_empty schema.validate(doc).map { |error| error["error"] },
                 "null service fields must still validate against the required-but-nullable schema"
  end


  def test_status_text_reports_running_daemon
    command = daemon("status")
    write_pid_payload(pid: 2468)
    File.utime(Time.now - 3, Time.now - 3, command.pid_file)
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, _pid| true }

    out, _err = capture_io { command.call }

    assert_match(/running \(pid 2468, uptime \d+s\)/, out)
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


  def test_stop_text_handles_malformed_pid_file
    command = daemon("stop")
    File.write(command.pid_file, "not a pid payload")

    _out, err = capture_io { command.call }

    assert_match(/PID file.*malformed/, err)
    refute File.exist?(command.pid_file)
  end

  def test_stop_json_reports_reused_and_unverified_pid_ownership
    reused = daemon("stop", json: true)
    write_pid_payload(pid: 1234)
    reused.define_singleton_method(:pid_alive?) { |_pid| true }
    reused.define_singleton_method(:pid_ownership) { |_payload, _pid| :reused }

    out, _err = capture_io { reused.call }
    doc = JSON.parse(out)
    assert_equal "pid_reused", doc.fetch("reason")
    refute File.exist?(reused.pid_file)

    unverified = daemon("stop", json: true)
    write_pid_payload(pid: 5678)
    unverified.define_singleton_method(:pid_alive?) { |_pid| true }
    unverified.define_singleton_method(:pid_ownership) { |_payload, _pid| :unverified }

    out, _err = capture_io { unverified.call }
    doc = JSON.parse(out)
    assert_equal "unverified", doc.fetch("reason")
    assert File.exist?(unverified.pid_file), "unverified pid is left for the operator to inspect"
  end

  def test_stop_aborts_kill_when_pid_ownership_flips_mid_stop
    command = daemon("stop")
    write_pid_payload(pid: 2468)
    signals = []
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    ownerships = [ :verified, :reused ]
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| ownerships.shift || :reused }
    command.define_singleton_method(:send_signal_safely) { |pid, signal| signals << [ pid, signal ] }
    base = Time.utc(2026, 5, 22, 12, 0, 0)
    times = [ base, base + 601 ]

    _out, err = with_replaced_singleton_method(Time, :now, -> { times.shift || base + 601 }) do
      capture_io { command.call }
    end

    assert_equal [ [ 2468, :TERM ] ], signals
    assert_match(/ownership flipped to reused/, err)
  end

  def test_stop_json_reports_success_after_term
    command = daemon("stop", json: true)
    write_pid_payload(pid: 1357)
    alive_results = [ true, false, false ]
    command.define_singleton_method(:pid_alive?) { |_pid| alive_results.shift }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :verified }
    command.define_singleton_method(:send_signal_safely) { |_pid, _signal| true }

    out, _err = capture_io { command.call }
    doc = JSON.parse(out)

    assert_equal true, doc.fetch("was_running")
    assert_equal false, doc.fetch("running")
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
      command.send(:emit_install_success_summary, installer, fake_outcome(:written))
      command.send(:emit_install_success_summary, installer,
                   fake_outcome(:upgraded, backup_path: "/tmp/hive-daemon.service.bak", restarted: true))
      command.send(:emit_install_success_summary, installer, fake_outcome(:unchanged))
      command.send(:emit_install_success_summary, installer, fake_outcome(:unsupported))
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
        command.send(:emit_install_outcome, installer, fake_outcome(:drifted))
      end
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "drifted", doc.fetch("outcome")
    assert_equal Hive::ExitCodes::USAGE, doc.fetch("exit_code")
  end


  def test_install_daemon_non_json_warns_messages_and_emits_success_summary
    require "hive/commands/daemon/service_installer"

    command = daemon("install")
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux-systemd-user",
      messages: [ "installed by fake" ]
    )
    installer.define_singleton_method(:install!) { |autostart:, force:| Hive::Commands::ServiceInstaller::Outcome.new(:written) }

    with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new, ->(**_kwargs) { installer }) do
      out, err = capture_io { command.call }
      assert_includes err, "hive: installed by fake"
      assert_includes out, "installed unit at /tmp/hive-daemon.service"
    end
  end

  def test_install_daemon_uses_invoked_wrapper_path_for_service_unit
    require "hive/commands/daemon/service_installer"

    with_tmp_dir do |dir|
      wrapper = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(wrapper))
      File.write(wrapper, "#!/bin/sh\n")
      FileUtils.chmod(0o755, wrapper)
      shim = File.join(dir, "gems", "shims", "hive")
      captured = nil
      command = daemon("install", json: true)
      installer = FakeInstaller.new(
        target_path: "/tmp/hive-daemon.service",
        last_backup_path: nil,
        last_restart_invoked: false,
        envelope_platform: "linux-systemd-user",
        messages: []
      )
      installer.define_singleton_method(:install!) { |autostart:, force:| Hive::Commands::ServiceInstaller::Outcome.new(:written) }

      previous_program = $PROGRAM_NAME
      with_env("HIVE_INVOKED_BIN" => wrapper) do
        $PROGRAM_NAME = shim
        with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new, lambda { |**kwargs|
          captured = kwargs
          installer
        }) do
          capture_io { command.call }
        end
      ensure
        $PROGRAM_NAME = previous_program
      end

      assert_equal wrapper, captured.fetch(:binary_path)
    end
  end

  def test_install_daemon_json_wraps_filesystem_errors
    require "hive/commands/daemon/service_installer"

    command = daemon("install", json: true)
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux-systemd-user",
      messages: [ "before write" ]
    )
    installer.define_singleton_method(:install!) do |autostart:, force:|
      raise Errno::EACCES, "denied"
    end

    out, _err = capture_io do
      assert_raises(Hive::DaemonInstallFailed) do
        with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new, ->(**_kwargs) { installer }) do
          command.call
        end
      end
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "failed", doc.fetch("outcome")
    assert_equal "DaemonInstallFailed", doc.fetch("error_class")
    assert_match(/Errno::EACCES/, doc.fetch("message"))
    assert_equal [ "before write" ], doc.fetch("messages")
  end

  def test_install_daemon_reraises_hive_errors_from_installer_without_exception_envelope
    require "hive/commands/daemon/service_installer"

    command = daemon("install", json: true)
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux-systemd-user",
      messages: []
    )
    installer.define_singleton_method(:install!) do |autostart:, force:|
      raise Hive::DaemonInstallFailed, "already wrapped"
    end

    out, _err = capture_io do
      assert_raises(Hive::DaemonInstallFailed) do
        with_replaced_singleton_method(Hive::Commands::Daemon::ServiceInstaller, :new, ->(**_kwargs) { installer }) do
          command.call
        end
      end
    end

    assert_equal "", out
  end

  def test_install_exception_envelope_helpers_have_safe_fallbacks
    command = daemon("install", json: true)
    broken = Object.new
    broken.define_singleton_method(:envelope_platform) { raise "platform unavailable" }
    broken.define_singleton_method(:target_path) { raise "target unavailable" }
    broken.define_singleton_method(:messages) { raise "messages unavailable" }

    assert_equal "unsupported", command.send(:safe_install_platform, broken)
    assert_nil command.send(:safe_install_target_path, broken)
    assert_equal [], command.send(:safe_install_messages, broken)
  end

  def test_emit_install_outcome_json_success_mappings
    command = daemon("install", json: true)
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: "/tmp/hive-daemon.service.bak",
      last_restart_invoked: true,
      envelope_platform: "linux-systemd-user",
      messages: []
    )

    expectations = {
      written: "written",
      upgraded: "upgraded",
      unchanged: "unchanged",
      unsupported: "unsupported",
      autostart_unavailable: "unsupported"
    }
    expectations.each do |result, outcome|
      out, _err = capture_io { command.send(:emit_install_outcome, installer, fake_outcome(result)) }
      doc = JSON.parse(out)
      assert_equal outcome, doc.fetch("outcome")
      assert_equal true, doc.fetch("ok"), "#{result} must be a success envelope"
    end
  end

  def test_emit_install_outcome_autostart_unavailable_preserves_target_path
    command = daemon("install", json: true)
    installer = FakeInstaller.new(
      target_path: "/home/u/.config/systemd/user/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux",
      messages: [ "systemd not detected; daemon unit was written but autostart was not enabled." ]
    )

    out, _err = capture_io { command.send(:emit_install_outcome, installer, fake_outcome(:autostart_unavailable)) }
    doc = JSON.parse(out)
    assert_equal "unsupported", doc.fetch("outcome")
    assert_equal true, doc.fetch("ok")
    assert_equal "/home/u/.config/systemd/user/hive-daemon.service", doc.fetch("target_path"),
                 "a written-but-not-enabled unit must still report where it lives"
  end

  def test_emit_install_success_summary_reports_autostart_unavailable_non_json
    command = daemon("install")
    installer = FakeInstaller.new(
      target_path: "/home/u/.config/systemd/user/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux",
      messages: []
    )

    out, _err = capture_io { command.send(:emit_install_success_summary, installer, fake_outcome(:autostart_unavailable)) }
    assert_includes out,
                    "hive daemon: unit written at /home/u/.config/systemd/user/hive-daemon.service; " \
                    "autostart not enabled on this host"
  end

  def test_emit_install_outcome_json_failed_raises_with_error_envelope
    command = daemon("install", json: true)
    installer = FakeInstaller.new(
      target_path: "/tmp/hive-daemon.service",
      last_backup_path: nil,
      last_restart_invoked: false,
      envelope_platform: "linux-systemd-user",
      messages: [ "systemctl failed" ]
    )

    out, _err = capture_io do
      assert_raises(Hive::DaemonInstallFailed) do
        command.send(:emit_install_outcome, installer, fake_outcome(:failed))
      end
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "failed", doc.fetch("outcome")
    assert_match(/reported a failure/, doc.fetch("message"))
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


  def test_error_kind_defaults_unknown_errors_to_internal
    command = daemon("enable")

    assert_equal Hive::Schemas::EnrollErrorKind::INTERNAL,
                 command.send(:error_kind_for, RuntimeError.new("boom"))
  end

  def test_atomic_rewrite_cleans_temp_file_when_rename_fails
    command = daemon("enable")
    cfg = File.join(@home, "config.yml")
    File.write(cfg, "daemon:\n  enabled: false\n")
    tmp = "#{cfg}.tmp.#{Process.pid}"

    with_replaced_singleton_method(File, :rename, ->(_from, _to) { raise Errno::EXDEV, "cross-device" }) do
      assert_raises(Hive::ConfigError) { command.send(:atomic_rewrite_with_lock, cfg, true) }
    end

    refute File.exist?(tmp), "failed atomic rewrite must delete its temp file"
  end

  def test_upsert_daemon_enabled_inserts_before_next_top_level_key
    command = daemon("enable")
    text = "daemon:\n  poll: 30\ndefault_branch: main\n"

    assert_equal "daemon:\n  enabled: true\n  poll: 30\ndefault_branch: main\n",
                 command.send(:upsert_daemon_enabled, text, true)
  end

  def test_read_live_pid_returns_verified_live_pid
    command = daemon("status")
    write_pid_payload(pid: 2468)
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, _pid| true }

    assert_equal 2468, command.send(:read_live_pid)
  end

  def test_pid_alive_treats_eperm_as_alive
    command = daemon("status")

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_equal true, command.send(:pid_alive?, 1234)
    end
  end

  def test_pid_owned_by_us_accepts_verified_and_legacy_only
    command = daemon("status")
    outcomes = [ :verified, :legacy, :reused ]
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| outcomes.shift }

    assert_equal true, command.send(:pid_owned_by_us?, {}, 1)
    assert_equal true, command.send(:pid_owned_by_us?, {}, 1)
    assert_equal false, command.send(:pid_owned_by_us?, {}, 1)
  end

  def test_warn_unsupported_json_flag_mentions_subcommand
    command = daemon("tail", json: true)

    _out, err = capture_io { command.send(:warn_unsupported_json_flag) }

    assert_match(/--json is not supported on `tail`/, err)
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
