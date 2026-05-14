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
      assert_equal 1, status
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
end
