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
  State = Struct.new(:slug, :project, :question_n, :mode, :awaiting_confirm, keyword_init: true)
  # A media update carries its text in the caption; update.text is nil. This
  # mirrors Telegram::Update#effective_text (caption for media, text otherwise).
  MediaUpdate = Struct.new(:chat_id, :text, :caption, :reply_to_text, keyword_init: true) do
    def effective_text
      caption
    end
  end

  def active_state
    State.new(slug: "slug-260522-abcd", project: "hive", question_n: 1, mode: :path_b, awaiting_confirm: false)
  end

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

  def test_media_caption_during_active_brainstorm_records_caption_not_blank
    result = handler(state: active_state).handle(
      MediaUpdate.new(chat_id: 12345, text: nil, caption: "my real caption")
    )

    assert_equal :write_answer_then_reply, result.action
    assert_equal "my real caption", result.answer_text,
                 "the caption must fill the answer slot, not a blank update.text"
  end

  def test_captionless_media_during_active_brainstorm_refuses_instead_of_writing_blank
    result = handler(state: active_state).handle(
      MediaUpdate.new(chat_id: 12345, text: nil, caption: nil)
    )

    assert_equal :reply, result.action,
                 "captionless media must not record a blank answer"
    assert_nil result.answer_text
  end
end
