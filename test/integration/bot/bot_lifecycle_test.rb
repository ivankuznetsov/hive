require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/bot"

class HiveBotLifecycleTest < Minitest::Test
  include HiveTestHelper

  def with_bot_home
    Dir.mktmpdir("hive-bot-home") do |home|
      old_home = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = home
      File.write(File.join(home, "config.yml"), {
        "bot" => { "chat_id_allowlist" => [ 12345 ] },
        "registered_projects" => []
      }.to_yaml)
      yield(home)
    ensure
      ENV["HIVE_HOME"] = old_home
    end
  end

  def test_status_json_reports_not_running_and_validates_schema
    with_bot_home do |home|
      out, _err, status = with_captured_exit do
        Hive::Commands::Bot.new("status", json: true).call
      end

      doc = JSON.parse(out)
      assert_equal 0, status
      assert_equal "hive-bot-status", doc["schema"]
      assert_equal false, doc["running"]
      assert_equal File.join(home, ".bot.pid"), doc["pid_file"]

      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
      assert_empty schema.validate(doc).map { |error| error["error"] }
    end
  end

  def test_stop_json_is_idempotent_and_validates_schema
    with_bot_home do |home|
      out, _err, status = with_captured_exit do
        Hive::Commands::Bot.new("stop", json: true).call
      end

      doc = JSON.parse(out)
      assert_equal 0, status
      assert_equal "hive-bot-stop", doc["schema"]
      assert_equal false, doc["running"]
      assert_equal false, doc["was_running"]
      assert_equal File.join(home, ".bot.pid"), doc["pid_file"]

      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-stop"))))
      assert_empty schema.validate(doc).map { |error| error["error"] }
    end
  end

  def test_reload_json_reports_not_running_and_validates_schema
    with_bot_home do
      out, _err, status = with_captured_exit do
        Hive::Commands::Bot.new("reload", json: true).call
      end

      doc = JSON.parse(out)
      assert_equal 1, status
      assert_equal "hive-bot-reload", doc["schema"]
      assert_equal false, doc["ok"]
      assert_equal "not_running", doc["reason"]

      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-reload"))))
      assert_empty schema.validate(doc).map { |error| error["error"] }
    end
  end

  def test_start_backgrounds_by_default
    with_bot_home do
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = "test-token"
      daemon_args = []
      fake_supervisor = Class.new do
        def run_forever
          raise StopIteration, "stop after startup"
        end
      end
      original_daemon = Process.method(:daemon)
      original_supervisor_new = Hive::Bot::Supervisor.method(:new)

      Process.define_singleton_method(:daemon) { |*args| daemon_args << args }
      Hive::Bot::Supervisor.define_singleton_method(:new) { |**_kwargs| fake_supervisor.new }

      assert_raises(StopIteration) do
        Hive::Commands::Bot.new("start", dry_run: true).send(:start_bot)
      end

      assert_equal [ [ true, true ] ], daemon_args
    ensure
      Process.define_singleton_method(:daemon, original_daemon) if original_daemon
      Hive::Bot::Supervisor.define_singleton_method(:new, original_supervisor_new) if original_supervisor_new
      ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
    end
  end

  def test_start_foreground_creates_pid_file_lockable_and_log_directory
    with_bot_home do |home|
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "test-token") do
        pid_path = File.join(home, ".bot.pid")
        log_dir = File.join(home, "logs")

        cmd = Hive::Commands::Bot.new("start", foreground: true, dry_run: true)

        pid = fork do
          cmd.send(:start_bot)
        rescue StandardError
          exit 1
        end

        begin
          wait_until_exists(pid_path)
          assert File.exist?(pid_path), "start should create the PID file"
          assert File.directory?(log_dir), "start should create the bot log directory"

          contender = File.open(pid_path, File::RDWR | File::CREAT)
          refute contender.flock(File::LOCK_EX | File::LOCK_NB),
                 "second start must not acquire the PID lock"
        ensure
          contender&.close
          Process.kill("TERM", pid) rescue nil
          Process.wait(pid) rescue nil
        end
      end
    end
  end

  def test_unknown_subcommand_returns_usage_error
    with_bot_home do
      err = assert_raises(Hive::InvalidTaskPath) { Hive::Commands::Bot.new("frobnicate").call }
      assert_match(/unknown subcommand/, err.message)
      assert_equal Hive::ExitCodes::USAGE, err.exit_code
    end
  end

  def test_custom_pid_and_log_paths_from_config_are_expanded
    with_bot_home do |home|
      custom_pid = File.join(home, "runtime", "bot.pid")
      custom_log = File.join(home, "runtime", "bot.log")
      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      data["bot"]["pid_file"] = custom_pid
      data["bot"]["log_file"] = custom_log
      File.write(File.join(home, "config.yml"), data.to_yaml)

      cmd = Hive::Commands::Bot.new("status")

      assert_equal custom_pid, cmd.pid_file
      assert_equal custom_log, cmd.log_file
    end
  end

  def test_start_refuses_when_pid_file_lock_is_held
    with_bot_home do |_home|
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "test-token") do
        cmd = Hive::Commands::Bot.new("start", dry_run: true)
        FileUtils.mkdir_p(File.dirname(cmd.pid_file))
        lock = File.open(cmd.pid_file, File::RDWR | File::CREAT, 0o644)
        lock.flock(File::LOCK_EX)
        lock.write({ "pid" => 12_345, "started_at" => Time.now.utc.iso8601 }.to_yaml)
        lock.flush
        lock.rewind

        error = assert_raises(Hive::ConcurrentRunError) { cmd.send(:start_bot) }
        assert_match(/already running/, error.message)
        assert_equal cmd.pid_file, error.lock_path
      ensure
        lock&.flock(File::LOCK_UN)
        lock&.close
      end
    end
  end

  def test_status_text_reports_running_with_uptime
    with_bot_home do |home|
      cmd = Hive::Commands::Bot.new("status")
      File.write(File.join(home, ".bot.pid"), {
        "pid" => Process.pid,
        "started_at" => (Time.now.utc - 5).iso8601
      }.to_yaml)

      out, _err = capture_io { cmd.call }

      assert_match(/hive bot: running \(pid #{Process.pid}, uptime \d+s\)/, out)
    end
  end

  def test_reload_text_sends_hup_to_live_pid
    with_bot_home do |home|
      cmd = Hive::Commands::Bot.new("reload")
      File.write(File.join(home, ".bot.pid"), { "pid" => Process.pid, "started_at" => Time.now.utc.iso8601 }.to_yaml)
      hup_seen = false
      old_hup = Signal.trap("HUP") { hup_seen = true }

      out, _err = capture_io { cmd.call }

      assert hup_seen, "reload must send HUP to the live bot pid"
      assert_match(/bot reload requested/, out)
    ensure
      Signal.trap("HUP", old_hup) if old_hup
    end
  end

  def test_stop_terminates_live_pid_and_removes_pid_file
    with_bot_home do |home|
      pid = fork { sleep 60 }
      pid_file = File.join(home, ".bot.pid")
      File.write(pid_file, { "pid" => pid, "started_at" => Time.now.utc.iso8601 }.to_yaml)

      cmd = Hive::Commands::Bot.new("stop")
      expected_pid = pid
      alive_checks = 0
      cmd.define_singleton_method(:pid_alive?) do |checked_pid|
        raise "unexpected pid #{checked_pid}" unless checked_pid == expected_pid

        alive_checks += 1
        alive_checks == 1
      end

      out, _err = capture_io { cmd.call }

      assert_match(/bot stopped \(pid #{pid}\)/, out)
      refute File.exist?(pid_file)
      _dead_pid, status = Process.waitpid2(pid)
      assert status.signaled? || !status.success?
    ensure
      begin
        Process.kill("KILL", pid) if pid
      rescue Errno::ESRCH, TypeError
      end
      Process.wait(pid) rescue nil
    end
  end

  def test_corrupted_pid_file_refuses_to_assume_state
    with_bot_home do |home|
      File.write(File.join(home, ".bot.pid"), "pid: [\n")

      _out, err = capture_io do
        error = assert_raises(Hive::Error) { Hive::Commands::Bot.new("status").call }
        assert_match(/corrupted/, error.message)
      end

      assert_match(/PID file.*corrupted/, err)
    end
  end

  private

  def wait_until_exists(path, deadline_sec: 3)
    deadline = Time.now + deadline_sec
    sleep 0.05 until File.exist?(path) || Time.now >= deadline
  end
end
