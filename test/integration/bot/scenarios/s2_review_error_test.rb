require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/status_watcher"
require "hive/bot/telegram"

class HiveBotScenarioReviewErrorTest < Minitest::Test
  def test_s2_clear_and_retry_maps_to_guarded_recovery
    row = Hive::Bot::StatusWatcher::Row.new(
      project: "hive",
      slug: "slug-260514-abcd",
      stage: "5-review",
      workflow: "coding",
      marker: "review_error",
      attrs: {},
      folder: "/tmp/slug-260514-abcd"
    )
    router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: StubLogger.new,
      conversation_store: Hive::Bot::ConversationStore.new,
      status_snapshot_provider: -> { [ row ] }
    )
    result = router.handle(update(callback_data: "clear_retry:hive:slug-260514-abcd:5-review:review_error"))

    assert_equal :dispatch_recovery, result.action
    assert_same row, result.recovery
    assert_nil result.commands
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
