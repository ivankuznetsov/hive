require "test_helper"
require "hive/commands/bot"

class HiveCommandsBotTest < Minitest::Test
  include HiveTestHelper

  FakeSupervisor = Struct.new(:calls) do
    def run_forever
      calls << :run_forever
    end
  end

  FakeLockFile = Struct.new(:calls) do
    def flock(_mode)
      true
    end

    def rewind
      calls << :rewind
    end

    def truncate(_length)
      calls << :truncate
    end

    def write(_payload)
      calls << :write
    end

    def flush
      calls << :flush
    end

    def close
      calls << :close
      raise IOError, "close failed"
    end
  end

  def setup
    @home = Dir.mktmpdir("hive-bot-command")
  end

  def teardown
    FileUtils.rm_rf(@home) if @home
  end

  def bot(subcommand, **kwargs)
    Hive::Commands::Bot.new(subcommand, **{ hive_home: @home }.merge(kwargs))
  end

  def configured_bot(subcommand, config: bot_config, **kwargs)
    command = bot(subcommand, **kwargs)
    command.define_singleton_method(:bot_config) { config }
    command
  end

  def bot_config(**overrides)
    {
      "pid_file" => File.join(@home, ".bot.pid"),
      "log_file" => File.join(@home, "logs", "bot.log"),
      "shutdown_grace_sec" => 0,
      "chat_id_allowlist" => [ 12345 ]
    }.merge(overrides.transform_keys(&:to_s))
  end

  def write_pid_payload(command, pid: 4242, started_at: Time.now.utc.iso8601)
    FileUtils.mkdir_p(File.dirname(command.pid_file))
    File.write(command.pid_file, { "pid" => pid, "started_at" => started_at }.to_yaml)
  end


  def test_call_routes_start_and_tail_subcommands
    routed = []

    [ [ "start", :start_bot, :start ], [ "tail", :tail_bot, :tail ] ].each do |subcommand, method_name, label|
      command = bot(subcommand)
      command.define_singleton_method(method_name) { routed << label }

      command.call
    end

    assert_equal %i[start tail], routed
  end

  def test_start_cleans_up_when_pid_payload_cleanup_fails
    command = configured_bot("start", dry_run: true)
    supervisor = FakeSupervisor.new([])
    command.define_singleton_method(:pid_file_payload) { raise "cannot parse pid payload" }

    with_replaced_singleton_method(Hive::Config, :telegram_bot_token!, -> { "test-token" }) do
      with_replaced_singleton_method(Hive::Bot::Supervisor, :new, ->(**_kwargs) { supervisor }) do
        command.call
      end
    end

    assert_equal [ :run_forever ], supervisor.calls
  end

  def test_start_ignores_lock_close_failures
    command = configured_bot("start", dry_run: true)
    supervisor = FakeSupervisor.new([])
    fake_lock_file = FakeLockFile.new([])
    original_file_open = File.method(:open)

    with_replaced_singleton_method(Hive::Config, :telegram_bot_token!, -> { "test-token" }) do
      with_replaced_singleton_method(Hive::Bot::Supervisor, :new, ->(**_kwargs) { supervisor }) do
        with_replaced_singleton_method(File, :open, lambda { |path, *args, &block|
          if path == command.pid_file && args.first == (File::RDWR | File::CREAT)
            fake_lock_file
          else
            original_file_open.call(path, *args, &block)
          end
        }) do
          command.call
        end
      end
    end

    assert_equal [ :run_forever ], supervisor.calls
    assert_includes fake_lock_file.calls, :close
  end

  def test_stop_text_when_not_running_warns_and_removes_stale_pid_file
    command = configured_bot("stop")
    write_pid_payload(command, pid: 9999)
    command.define_singleton_method(:live_pid) { nil }

    out, err = capture_io { command.call }

    assert_empty out
    assert_includes err, "hive: bot not running"
    refute File.exist?(command.pid_file)
  end

  def test_stop_escalates_to_kill_when_pid_survives_grace_period
    command = configured_bot("stop")
    write_pid_payload(command, pid: 2468)
    command.define_singleton_method(:live_pid) { 2468 }
    alive_checks = [ true, true, true, false ]
    command.define_singleton_method(:pid_alive?) { |_pid| alive_checks.shift || false }
    command.define_singleton_method(:sleep) { |_seconds| true }
    signals = []
    base = Time.utc(2026, 5, 22, 12, 0, 0)
    times = [ base, base + 1, base + 1, base + 2, base + 7 ]

    with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
      with_replaced_singleton_method(Time, :now, -> { times.shift || base + 7 }) do
        capture_io { command.call }
      end
    end

    assert_equal [ [ "TERM", 2468 ], [ "KILL", 2468 ] ], signals
    refute File.exist?(command.pid_file)
  end

  def test_stop_removes_pid_file_when_term_finds_no_process
    command = configured_bot("stop")
    write_pid_payload(command, pid: 1357)
    command.define_singleton_method(:live_pid) { 1357 }

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      capture_io { command.call }
    end

    refute File.exist?(command.pid_file)
  end

  def test_status_text_tolerates_invalid_started_at
    command = configured_bot("status")
    write_pid_payload(command, pid: 1234, started_at: "not a timestamp")
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }

    out, _err = capture_io { command.call }

    assert_includes out, "hive bot: running (pid 1234, uptime s)"
  end

  def test_tail_missing_log_warns_and_raises
    command = configured_bot("tail")

    _out, err = capture_io do
      error = assert_raises(Hive::Error) { command.call }
      assert_equal "bot log file missing", error.message
    end

    assert_includes err, "hive: bot log file not found at #{command.log_file}"
  end

  def test_tail_streams_appended_log_until_interrupted
    command = configured_bot("tail")
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

  def test_pid_alive_reports_missing_process_and_permission_denied_process
    command = configured_bot("status")
    outcomes = [ Errno::ESRCH, Errno::EPERM ]

    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid|
      outcome = outcomes.shift
      raise outcome if outcome
    }) do
      refute command.send(:pid_alive?, 1)
      assert command.send(:pid_alive?, 2)
    end
  end
end
