require "test_helper"
require "hive/bot/handlers/free_text_handler"

class HiveBotFreeTextHandlerTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :question_n, :answer_text, :mode,
                      :intent, keyword_init: true)
  Store = Struct.new(:state, keyword_init: true) do
    def get(chat_id:)
      state
    end
  end
  Update = Struct.new(:chat_id, :text, :reply_to_text, keyword_init: true)
  LegacyUpdate = Struct.new(:chat_id, :text, keyword_init: true)

  def handler(state: nil)
    Hive::Bot::Handlers::FreeTextHandler.new(
      conversation_store: Store.new(state: state),
      result_class: Result
    )
  end

  def test_unknown_free_text_without_reply_context_gets_help
    result = handler.handle(LegacyUpdate.new(chat_id: 12345, text: "hello"))

    assert_equal :reply, result.action
    assert_equal "Send /help for commands.", result.text
  end

  def test_unmatched_reply_context_gets_help
    result = handler.handle(
      Update.new(chat_id: 12345, text: "hello", reply_to_text: "no task reference here")
    )

    assert_equal :reply, result.action
    assert_equal "Send /help for commands.", result.text
  end

  def test_legacy_answer_mode_reply_reattaches_without_project
    result = handler.handle(
      Update.new(
        chat_id: 12345,
        text: "offline answer",
        reply_to_text: "Answer mode started for slug-260522-abcd."
      )
    )

    assert_equal :write_answer_then_reply, result.action
    assert_nil result.project
    assert_equal "slug-260522-abcd", result.slug
    assert_nil result.question_n
    assert_equal "offline answer", result.answer_text
    assert_equal :path_b, result.mode
  end
end
