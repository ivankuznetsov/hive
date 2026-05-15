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
          unless state
            reattached = reattach_from_reply(update)
            return @result_class.new(action: :reply, text: "Send /help for commands.") unless reattached

            return @result_class.new(
              action: :write_answer_then_reply,
              project: reattached[:project],
              slug: reattached.fetch(:slug),
              question_n: nil,
              answer_text: update.text.to_s,
              mode: :path_b
            )
          end

          if state.mode == :path_a && !state.awaiting_confirm
            return @result_class.new(
              action: :start_codex,
              project: state.project,
              slug: state.slug,
              question_n: state.question_n,
              answer_text: update.text.to_s,
              mode: :path_a
            )
          end

          @result_class.new(
            action: :write_answer_then_reply,
            project: state.project,
            slug: state.slug,
            question_n: state.question_n,
            answer_text: update.text.to_s,
            mode: state.mode
          )
        end

        private

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
