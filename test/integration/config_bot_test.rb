require "test_helper"
require "erb"
require "hive/config"

class ConfigBotIntegrationTest < Minitest::Test
  include HiveTestHelper

  def test_global_config_template_documents_bot_block_and_env_token
    template_path = File.expand_path("../../templates/hive_config.yml.erb", __dir__)
    registered_projects = []

    rendered = ERB.new(File.read(template_path), trim_mode: "-").result(binding)

    assert_includes rendered, "bot:"
    assert_includes rendered, "HIVE_TELEGRAM_BOT_TOKEN"
    assert_includes rendered, "chat_id_allowlist"
    assert_includes rendered, "alert_state_file"
    assert_includes rendered, "recovery_reminder_window_sec"
    assert_includes rendered, "last_seen_state_file"
  end

  def test_bot_defaults_include_alert_lifecycle_settings
    with_tmp_dir do |project|
      with_tmp_dir do |home|
        with_env("HOME" => home) do
          cfg = Hive::Config.load(project)

          assert_equal File.join(Hive::Paths.state_home, ".bot.alert_state.json"),
                       cfg.dig("bot", "alert_state_file")
          assert_equal 28_800, cfg.dig("bot", "recovery_reminder_window_sec")
        end
      end
    end
  end

  def test_recovery_reminder_window_is_bounded
    with_tmp_dir do |project|
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      File.write(File.join(project, ".hive-state", "config.yml"), <<~YAML)
        bot:
          recovery_reminder_window_sec: 60
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(project) }

      assert_match(/bot.recovery_reminder_window_sec.*between 3600 and 604800/, err.message)
    end
  end

  def test_global_bot_alert_state_file_uses_state_home
    with_tmp_global_config do |home|
      cfg = Hive::Config.load_global_bot

      assert_equal File.join(home, ".bot.alert_state.json"), cfg["alert_state_file"]
    end
  end
end
