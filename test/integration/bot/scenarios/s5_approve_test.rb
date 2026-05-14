require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/telegram"

class HiveBotScenarioApproveTest < Minitest::Test
  CASES = [
    [ "brainstorm", "1-inbox" ],
    [ "plan", "2-brainstorm" ],
    [ "develop", "3-plan" ],
    [ "review", "4-execute" ],
    [ "pr", "5-review" ],
    [ "archive", "6-pr" ]
  ].freeze

  def test_s5_stage_approval_callbacks_dispatch_workflow_verbs
    router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: StubLogger.new,
      conversation_store: Hive::Bot::ConversationStore.new
    )

    CASES.each do |verb, stage|
      result = router.handle(update("approve:#{verb}:hive:slug-260514-abcd:#{stage}"))
      assert_equal :dispatch_then_reply, result.action
      assert_equal [ "hive", verb, "slug-260514-abcd", "--from", stage,
                     "--project", "hive", "--json" ], result.command_argv
    end
  end

  private

  def update(callback_data)
    Hive::Bot::Telegram::Update.new(update_id: 1, chat_id: 12345,
                                    from_id: 12345, callback_data: callback_data)
  end

  class StubLogger
    def event(_name, **_attrs); end
  end
end
