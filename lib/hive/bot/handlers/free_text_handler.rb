module Hive
  module Bot
    module Handlers
      class FreeTextHandler
        def initialize(conversation_store:, result_class:)
          @conversation_store = conversation_store
          @result_class = result_class
        end

        def handle(update)
          state = @conversation_store.get(chat_id: update.chat_id)
          return @result_class.new(action: :reply, text: "Send /help for commands.") unless state

          @result_class.new(
            action: :write_answer_then_reply,
            slug: state.slug,
            question_n: state.question_n,
            answer_text: update.text.to_s
          )
        end
      end
    end
  end
end
