require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/telegram"

class HiveBotScenarioIdeaTest < Minitest::Test
  def test_s4_idea_project_picker_dispatches_hive_new
    projects = [
      { "name" => "hive", "path" => "/tmp/hive", "hive_state_path" => "/tmp/hive/.hive-state" },
      { "name" => "writero", "path" => "/tmp/writero", "hive_state_path" => "/tmp/writero/.hive-state" }
    ]
    router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: StubLogger.new,
      conversation_store: Hive::Bot::ConversationStore.new,
      projects_provider: -> { projects }
    )

    picker = router.handle(update(text: "/idea fix the broken cron"))
    hive_button = picker.reply_markup.flatten.detect { |button| button[:text].to_s.include?("hive") }
    refute_nil hive_button, "picker keyboard should expose a 'hive' option"
    result = router.handle(update(callback_data: hive_button[:callback_data]))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "new", "hive", "fix the broken cron", "--json" ], result.command_argv
  end

  private

  def update(text: nil, callback_data: nil)
    Hive::Bot::Telegram::Update.new(update_id: 1, chat_id: 12345,
                                    from_id: 12345, text: text, callback_data: callback_data)
  end

  class StubLogger
    def event(_name, **_attrs); end
  end
end
