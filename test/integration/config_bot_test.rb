require "test_helper"
require "erb"

class ConfigBotIntegrationTest < Minitest::Test
  def test_global_config_template_documents_bot_block_and_env_token
    template_path = File.expand_path("../../templates/hive_config.yml.erb", __dir__)
    registered_projects = []

    rendered = ERB.new(File.read(template_path), trim_mode: "-").result(binding)

    assert_includes rendered, "bot:"
    assert_includes rendered, "HIVE_TELEGRAM_BOT_TOKEN"
    assert_includes rendered, "chat_id_allowlist"
    assert_includes rendered, "last_seen_state_file"
  end
end
