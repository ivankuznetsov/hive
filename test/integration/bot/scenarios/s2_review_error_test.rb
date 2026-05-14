require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/telegram"

class HiveBotScenarioReviewErrorTest < Minitest::Test
  def test_s2_clear_and_retry_maps_to_marker_clear_then_review
    router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: StubLogger.new,
      conversation_store: Hive::Bot::ConversationStore.new
    )
    result = router.handle(update(callback_data: "clear_retry:hive:slug-260514-abcd:5-review:review_error"))

    assert_equal :dispatch_commands, result.action
    assert_equal [ "hive", "markers", "clear", "slug-260514-abcd", "--name",
                   "REVIEW_ERROR", "--project", "hive", "--json" ], result.commands.first
    assert_equal [ "hive", "review", "slug-260514-abcd", "--from", "5-review",
                   "--project", "hive", "--json" ], result.commands.last
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
