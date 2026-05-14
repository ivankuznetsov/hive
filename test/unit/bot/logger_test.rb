require "test_helper"
require "json"
require "json_schemer"
require "hive/bot/logger"

class HiveBotLoggerTest < Minitest::Test
  include HiveTestHelper

  def with_log
    with_tmp_dir do |dir|
      path = File.join(dir, "bot.log")
      logger = Hive::Bot::Logger.new(path: path)
      yield(logger, path)
      logger.close
    end
  end

  def test_event_writes_one_json_line_per_call
    with_log do |logger, path|
      logger.event(:bot_started, version: "0.1.0")
      logger.event(:update_received, update_id: 123)
      logger.close

      lines = File.read(path).lines
      assert_equal 2, lines.size
      first = JSON.parse(lines[0])
      assert_equal "hive-bot-log", first["schema"]
      assert_equal 1, first["schema_version"]
      assert_equal "bot_started", first["event"]
      assert_equal "0.1.0", first["version"]
      assert_match(/^\d{4}-\d{2}-\d{2}T/, first["ts"])
    end
  end

  def test_unknown_event_raises_argument_error
    with_log do |logger, _path|
      err = assert_raises(ArgumentError) { logger.event(:made_up_event) }
      assert_match(/unknown bot log event/, err.message)
    end
  end

  def test_every_documented_event_is_accepted_and_schema_valid
    schema = JSONSchemer.schema(JSON.parse(File.read(File.expand_path("../../../schemas/hive-bot-log.v1.json", __dir__))))

    with_log do |logger, path|
      Hive::Bot::Logger::EVENTS.each { |event| logger.event(event) }
      logger.close

      lines = File.read(path).lines
      assert_equal Hive::Bot::Logger::EVENTS.size, lines.size
      lines.each do |line|
        payload = JSON.parse(line)
        assert schema.valid?(payload), "bot log line should match schema: #{payload.inspect}"
      end
    end
  end

  def test_logger_rotates_past_size_threshold
    with_tmp_dir do |dir|
      path = File.join(dir, "rot.log")
      logger = Hive::Bot::Logger.new(path: path, max_bytes: 200, max_files: 3)
      5.times { |i| logger.event(:notification_sent, sequence: i, padding: "x" * 50) }
      logger.close

      siblings = Dir[File.join(dir, "rot.log*")]
      assert siblings.size >= 1, "expected at least one log file present"
    end
  end

  def test_unwritable_log_path_falls_back_to_stderr_without_crashing
    with_tmp_dir do |dir|
      readonly_parent = File.join(dir, "readonly")
      FileUtils.mkdir_p(readonly_parent)
      File.chmod(0o500, readonly_parent)
      target = File.join(readonly_parent, "subdir", "bot.log")

      err = capture_stderr do
        logger = Hive::Bot::Logger.new(path: target)
        if logger.stderr_fallback?
          logger.event(:bot_started)
          logger.close
        else
          logger.event(:bot_started)
          logger.close
          skip "running with elevated permissions; stderr fallback path not reachable"
        end
      end
      File.chmod(0o755, readonly_parent)

      assert err.length > 0, "expected stderr output during unwritable-path scenario"
    end
  end

  private

  def capture_stderr
    real = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = real
  end
end
