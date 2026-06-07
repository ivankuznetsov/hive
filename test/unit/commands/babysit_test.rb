require "test_helper"
require "hive/commands/babysit"
require "hive/invoked_binary"

class HiveCommandsBabysitTest < Minitest::Test
  include HiveTestHelper

  FakeDispatcher = Struct.new(:calls) do
    def run_forever
      calls << :run_forever
    end
  end

  def babysit(subcommand = nil, **kwargs)
    Hive::Commands::Babysit.new(subcommand, **{ hive_home: @home }.merge(kwargs))
  end

  def setup
    @home = Dir.mktmpdir("hive-babysit-command")
  end

  def teardown
    FileUtils.rm_rf(@home) if @home
  end

  def daemon_config
    {
      "log_max_bytes" => 1024,
      "log_max_files" => 2
    }
  end

  def write_pid_payload(pid: 4242, process_start_time: "start-time")
    FileUtils.mkdir_p(@home)
    File.write(
      File.join(@home, ".babysitter.pid"),
      {
        "pid" => pid,
        "process_start_time" => process_start_time,
        "started_at" => Time.now.utc.iso8601
      }.to_yaml
    )
  end

  def test_start_writes_pid_runs_dispatcher_and_cleans_pid
    command = babysit("start", dry_run: true)
    dispatcher = FakeDispatcher.new([])
    captured = nil
    config = daemon_config

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(pid) { "start-#{pid}" }) do
      with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { config }) do
        with_replaced_singleton_method(Hive::Babysitter::Dispatcher, :new, lambda { |**kwargs|
          captured = kwargs
          dispatcher
        }) do
          command.call
        end
      end
    end

    assert_equal [ :run_forever ], dispatcher.calls
    assert_equal true, captured.fetch(:dry_run)
    refute File.exist?(command.pid_file)
  end

  def test_start_refuses_when_pid_file_points_to_live_babysitter
    command = babysit("start")
    command.define_singleton_method(:read_live_pid) { 2222 }

    err = assert_raises(Hive::ConcurrentRunError) { command.call }
    assert_match(/already running/, err.message)
    assert_equal 2222, err.holder.fetch(:pid)
  end

  def test_status_not_running_exits_error_after_message
    command = babysit("status")

    out, _err = capture_io do
      assert_raises(Hive::Error) { command.call }
    end

    assert_includes out, "not running"
  end

  def test_status_reports_verified_running_babysitter
    command = babysit("status")
    write_pid_payload(pid: 1234)
    File.utime(Time.now - 5, Time.now - 5, command.pid_file)
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, pid| pid == 1234 }

    out, _err = capture_io { command.call }
    assert_match(/running \(pid 1234, uptime \d+s\)/, out)
  end

  def test_status_recommends_restart_when_runtime_predates_source
    command = babysit("status")
    write_pid_payload(pid: 1234)
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }
    command.define_singleton_method(:pid_owned_by_us?) { |_payload, pid| pid == 1234 }
    command.define_singleton_method(:current_source_mtime) { Time.now + 60 }

    out, _err = capture_io { command.call }
    assert_includes out, "restart recommended"
    assert_includes out, "hive babysit restart --detach"
  end

  def test_once_unknown_project_is_usage_error
    with_tmp_global_config do
      err = assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::Babysit.new(nil, "missing", once: true, hive_home: @home).call
      end
      assert_match(/unknown project/, err.message)
    end
  end

  def test_once_registered_project_runs_one_dispatcher_pass
    with_tmp_global_config do |home|
      with_tmp_dir do |project|
        data = YAML.safe_load(File.read(File.join(home, "config.yml")))
        data["registered_projects"] = [ { "name" => "proj", "path" => project } ]
        File.write(File.join(home, "config.yml"), data.to_yaml)

        dispatcher = FakeDispatcher.new([])
        captured = nil
        config = daemon_config
        with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { config }) do
          with_replaced_singleton_method(Hive::Babysitter::Dispatcher, :new, lambda { |**kwargs|
            captured = kwargs
            dispatcher
          }) do
            Hive::Commands::Babysit.new(nil, "proj", once: true, hive_home: @home).call
          end
        end

        assert_equal [ :run_forever ], dispatcher.calls
        assert_equal "proj", captured.fetch(:project_name)
        assert_equal 1, captured.fetch(:max_ticks)
      end
    end
  end

  def test_reload_success_sends_hup
    command = babysit("reload")
    write_pid_payload(pid: 1234)
    signals = []
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :verified }
    command.define_singleton_method(:send_signal_safely) { |pid, signal| signals << [ pid, signal ] }

    out, _err = capture_io { command.call }
    assert_equal [ [ 1234, :HUP ] ], signals
    assert_includes out, "reload requested"
  end

  def test_reload_warns_when_runtime_predates_source
    command = babysit("reload")
    write_pid_payload(pid: 1234)
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_ownership) { |_payload, _pid| :verified }
    command.define_singleton_method(:send_signal_safely) { |_pid, _signal| nil }
    command.define_singleton_method(:current_source_mtime) { Time.now + 60 }

    _out, err = capture_io { command.call }
    assert_includes err, "reload will not update Ruby code"
    assert_includes err, "hive babysit restart --detach"
  end

  def test_restart_stops_existing_process_then_starts
    command = babysit("restart")
    calls = []
    home = @home
    command.define_singleton_method(:pid_file) { File.join(home, ".babysitter.pid") }
    File.write(command.pid_file, { "pid" => 1234 }.to_yaml)
    command.define_singleton_method(:stop_daemon) { calls << :stop }
    command.define_singleton_method(:start_daemon) { calls << :start }

    command.call
    assert_equal %i[stop start], calls
  end

  def test_detached_restart_reexecs_canonical_start_command
    command = babysit("restart", detach: true, dry_run: true)
    calls = []
    home = @home
    command.define_singleton_method(:pid_file) { File.join(home, ".babysitter.pid") }
    File.write(command.pid_file, { "pid" => 1234 }.to_yaml)
    command.define_singleton_method(:stop_daemon) { calls << :stop }
    command.define_singleton_method(:start_daemon) { calls << :start }

    exec_args = nil
    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/tmp/hive-wrapper/bin/hive" }) do
      with_replaced_singleton_method(Kernel, :exec, lambda { |*args| exec_args = args; throw :exec_called }) do
        assert_raises(UncaughtThrowError) { command.call }
      end
    end

    assert_equal [ :stop ], calls
    assert_equal [ "/tmp/hive-wrapper/bin/hive", "babysit", "start", "--detach", "--dry-run" ], exec_args
  end

  def test_detached_restart_without_dry_run_omits_dry_run_flag
    command = babysit("restart", detach: true)
    home = @home
    command.define_singleton_method(:pid_file) { File.join(home, ".babysitter.pid") }
    File.write(command.pid_file, { "pid" => 1234 }.to_yaml)
    command.define_singleton_method(:stop_daemon) { true }

    exec_args = nil
    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/tmp/hive-wrapper/bin/hv" }) do
      with_replaced_singleton_method(Kernel, :exec, lambda { |*args| exec_args = args; throw :exec_called }) do
        assert_raises(UncaughtThrowError) { command.call }
      end
    end

    assert_equal [ "/tmp/hive-wrapper/bin/hv", "babysit", "start", "--detach" ], exec_args
  end

  def test_detached_restart_surfaces_reexec_failure
    command = babysit("restart", detach: true)
    calls = []
    home = @home
    command.define_singleton_method(:pid_file) { File.join(home, ".babysitter.pid") }
    File.write(command.pid_file, { "pid" => 1234 }.to_yaml)
    command.define_singleton_method(:stop_daemon) { calls << :stop }

    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { "/tmp/hive-wrapper/bin/hive" }) do
      with_replaced_singleton_method(Kernel, :exec, ->(*_args) { raise Errno::ENOENT, "missing hive" }) do
        error = assert_raises(Hive::Error) { command.call }
        assert_includes error.message, "failed to re-exec detached start"
      end
    end
    assert_equal [ :stop ], calls
  end

  def test_detached_restart_errors_when_invoked_binary_cannot_be_resolved
    command = babysit("restart", detach: true)
    calls = []
    home = @home
    command.define_singleton_method(:pid_file) { File.join(home, ".babysitter.pid") }
    File.write(command.pid_file, { "pid" => 1234 }.to_yaml)
    command.define_singleton_method(:stop_daemon) { calls << :stop }

    with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { nil }) do
      error = assert_raises(Hive::Error) { command.call }
      assert_includes error.message, "failed to resolve invoked hive binary"
    end
    assert_equal [ :stop ], calls
  end

  def test_restart_aborts_when_stop_leaves_existing_process_alive
    command = babysit("restart")
    calls = []
    home = @home
    command.define_singleton_method(:pid_file) { File.join(home, ".babysitter.pid") }
    File.write(command.pid_file, { "pid" => 1234 }.to_yaml)
    command.define_singleton_method(:stop_daemon) { calls << :stop; false }
    command.define_singleton_method(:start_daemon) { calls << :start }

    error = assert_raises(Hive::Error) { command.call }

    assert_equal [ :stop ], calls
    assert_includes error.message, "stop failed"
  end

  def test_stop_leaves_pid_file_when_kill_ownership_becomes_unverified
    command = babysit("stop")
    write_pid_payload(pid: 1234)
    signals = []
    command.define_singleton_method(:pid_alive?) { |_pid| true }
    command.define_singleton_method(:pid_ownership) do |_payload, _pid|
      signals.empty? ? :verified : :unverified
    end
    command.define_singleton_method(:send_signal_safely) { |_pid, signal| signals << signal }
    command.define_singleton_method(:sleep) { |_sec| nil }
    times = [ Time.at(0), Time.at(Hive::Commands::Babysit::STOP_GRACE_SEC + 1) ]

    _out, err = capture_io do
      assert_raises(Hive::Error) do
        with_replaced_singleton_method(Time, :now, -> { times.shift || Time.at(Hive::Commands::Babysit::STOP_GRACE_SEC + 1) }) do
          command.call
        end
      end
    end

    assert_equal [ :TERM ], signals
    assert File.exist?(command.pid_file)
    assert_includes err, "refusing KILL"
  end

  def test_stale_runtime_ignores_malformed_started_at
    command = babysit("status")
    command.define_singleton_method(:current_source_mtime) { Time.now + 60 }

    refute command.send(:stale_runtime?, { "started_at" => "not-a-time" })
  end

  def test_current_source_mtime_returns_nil_when_source_scan_fails
    command = babysit("status")
    original_glob = Dir.method(:glob)
    Dir.define_singleton_method(:glob) { |_pattern| raise Errno::EACCES, "blocked" }

    assert_nil command.send(:current_source_mtime)
  ensure
    Dir.define_singleton_method(:glob, original_glob) if original_glob
  end
end
