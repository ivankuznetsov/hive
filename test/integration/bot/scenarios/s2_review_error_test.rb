require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/telegram"

class HiveBotScenarioReviewErrorTest < Minitest::Test
  def test_s2_autofix_maps_to_generation_fenced_coordinator_intent
    router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: StubLogger.new,
      conversation_store: Hive::Bot::ConversationStore.new
    )
    result = router.handle(
      update(callback_data: "autofix:hive:slug-260514-abcd:5-review:review_error:generation=4")
    )

    assert_equal :dispatch_commands, result.action
    assert_equal [ %w[hive retry manual slug-260514-abcd --project hive --generation 4 --json] ],
                 result.commands
  end

  private

  def update(callback_data:)
    Hive::Bot::Telegram::Update.new(update_id: 1, chat_id: 12345,
                                    from_id: 12345, callback_data: callback_data)
  end

  class StubLogger
    def event(_name, **_attrs); end
  end
end
