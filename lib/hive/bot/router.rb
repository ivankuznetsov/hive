require "securerandom"
require "hive/config"
require "hive/bot/handlers/slash_handlers"
require "hive/bot/handlers/callback_handlers"
require "hive/bot/handlers/free_text_handler"

module Hive
  module Bot
    class Router
      INTENTS = %i[
        slash_status
        slash_queue
        slash_idea
        slash_answer
        slash_approve
        slash_done
        slash_help
        callback_approve
        callback_reject
        callback_clear_and_retry
        callback_open_laptop
        callback_show_details
        callback_answer
        callback_idea_project_pick
        callback_path_a_yes
        callback_path_a_just_type
        callback_codex_write_draft
        callback_codex_edit
        callback_codex_cancel
        callback_findings_accept_all
        callback_findings_reject_all
        free_text_answer
        unauthorized
        unknown
      ].freeze

      Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                          :project, :slug, :question_n, :answer_text, :mode,
                          :intent, keyword_init: true)

      def initialize(bot_config:, logger:, conversation_store:,
                     projects_provider: -> { Hive::Config.registered_projects })
        @bot_config = bot_config
        @logger = logger
        @conversation_store = conversation_store
        @projects_provider = projects_provider
        @unauthorized_logged = {}
        @pending_ideas = {}
        @last_project = nil

        @slash_handlers = Handlers::SlashHandlers.new(
          projects_provider: @projects_provider,
          pending_ideas: @pending_ideas,
          last_project: -> { @last_project },
          result_class: Result
        )
        @callback_handlers = Handlers::CallbackHandlers.new(
          pending_ideas: @pending_ideas,
          set_last_project: ->(project) { @last_project = project },
          conversation_store: @conversation_store,
          result_class: Result
        )
        @free_text_handler = Handlers::FreeTextHandler.new(
          conversation_store: @conversation_store,
          result_class: Result
        )
      end

      def classify(update)
        return :unauthorized unless authorized?(update.chat_id)

        if update.callback_query?
          return callback_intent(update.callback_data.to_s)
        end

        text = update.text.to_s.strip
        case text
        when %r{\A/status\b} then :slash_status
        when %r{\A/queue\b} then :slash_queue
        when %r{\A/idea\b} then :slash_idea
        when %r{\A/answer\b} then :slash_answer
        when %r{\A/approve\b} then :slash_approve
        when %r{\A/done\b} then :slash_done
        when %r{\A/help\b} then :slash_help
        else
          @conversation_store.get(chat_id: update.chat_id) ? :free_text_answer : :unknown
        end
      end

      def handle(update)
        intent = classify(update)
        @logger.event(:update_received, update_id: update.update_id,
                                        chat_id: update.chat_id,
                                        intent: intent.to_s) unless intent == :unauthorized
        result = dispatch(intent, update)
        result.intent = intent if result.respond_to?(:intent=)
        result
      end

      private

      def authorized?(chat_id)
        allowed = Array(@bot_config.fetch("chat_id_allowlist"))
        return true if allowed.include?(chat_id)

        unless @unauthorized_logged[chat_id]
          @logger.event(:update_rejected_unauthorized, chat_id: chat_id)
          @unauthorized_logged[chat_id] = true
        end
        false
      end

      def callback_intent(data)
        case data
        when /\Aapprove:/ then :callback_approve
        when /\Areject:/ then :callback_reject
        when /\Aclear_retry:/ then :callback_clear_and_retry
        when /\Aopen_laptop:/ then :callback_open_laptop
        when /\Adetails:/ then :callback_show_details
        when /\Aanswer:/ then :callback_answer
        when /\Aidea_project:/ then :callback_idea_project_pick
        when /\Apath_a_yes:/ then :callback_path_a_yes
        when /\Apath_a_type:/ then :callback_path_a_just_type
        when /\Acodex_write:/ then :callback_codex_write_draft
        when /\Acodex_edit:/ then :callback_codex_edit
        when /\Acodex_cancel:/ then :callback_codex_cancel
        when /\Afindings:accept_all:/ then :callback_findings_accept_all
        when /\Afindings:reject_all:/ then :callback_findings_reject_all
        else :unknown
        end
      end

      def dispatch(intent, update)
        case intent
        when :unauthorized then Result.new(action: :noop)
        when :slash_status then @slash_handlers.status(update)
        when :slash_queue then @slash_handlers.queue(update)
        when :slash_idea then @slash_handlers.idea(update)
        when :slash_answer then @slash_handlers.answer(update, @conversation_store)
        when :slash_approve then @slash_handlers.approve(update)
        when :slash_done then @slash_handlers.done(update, @conversation_store)
        when :slash_help then @slash_handlers.help(update)
        when :free_text_answer then @free_text_handler.handle(update)
        when :unknown then Result.new(action: :reply, text: "I did not understand that. Send /help for commands.")
        else @callback_handlers.handle(intent, update)
        end
      end
    end
  end
end
