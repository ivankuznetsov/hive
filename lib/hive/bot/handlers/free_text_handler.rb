module Hive
  module Bot
    module Handlers
      class FreeTextHandler
        def initialize(conversation_store:, result_class:)
          @conversation_store = conversation_store
          @result_class = result_class
        end

        def handle(update)
          # Read effective_text, not text: a media message carries its text in
          # the caption (update.text is nil). The router routes captioned media
          # sent during an active brainstorm here (answer-wins precedence), so
          # reading update.text would record a blank answer and silently drop
          # the operator's caption.
          answer_text = effective_text(update)
          state = @conversation_store.get(chat_id: update.chat_id)
          unless state
            reattached = reattach_from_reply(update)
            return @result_class.new(action: :reply, text: "Send /help for commands.") unless reattached
            return blank_answer_refusal if blank?(answer_text)

            return @result_class.new(
              action: :write_answer_then_reply,
              project: reattached[:project],
              slug: reattached.fetch(:slug),
              question_n: nil,
              answer_text: answer_text,
              mode: :path_b
            )
          end

          return blank_answer_refusal if blank?(answer_text)

          if state.mode == :path_a && !state.awaiting_confirm
            return @result_class.new(
              action: :start_codex,
              project: state.project,
              slug: state.slug,
              question_n: state.question_n,
              answer_text: answer_text,
              mode: :path_a
            )
          end

          @result_class.new(
            action: :write_answer_then_reply,
            project: state.project,
            slug: state.slug,
            question_n: state.question_n,
            answer_text: answer_text,
            mode: state.mode
          )
        end

        private

        def effective_text(update)
          (update.respond_to?(:effective_text) ? update.effective_text : update.text).to_s
        end

        def blank?(text)
          text.to_s.strip.empty?
        end

        # A media message with no caption carries no answer text. Refuse rather
        # than record a blank answer for the pending brainstorm question.
        def blank_answer_refusal
          @result_class.new(action: :reply,
                            text: "I need text to record that answer. Reply with your answer as a text message.")
        end

        def reattach_from_reply(update)
          text = update.respond_to?(:reply_to_text) ? update.reply_to_text.to_s : ""
          return nil if text.empty?

          if (match = text.match(%r{(?:\A|\s)(?<project>[A-Za-z0-9_.-]+)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])\s*\(}))
            return { project: match[:project], slug: match[:slug] }
          end
          if (match = text.match(/\AAnswer mode started for (?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])\./))
            return { project: nil, slug: match[:slug] }
          end

          nil
        end
      end
    end
  end
end
