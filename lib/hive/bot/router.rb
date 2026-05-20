require "securerandom"
require "set"
require "time"
require "hive/config"
require "hive/bot/notification_builders"
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
        callback_refresh_diagnose
        callback_answer
        callback_idea_project_pick
        callback_path_a_yes
        callback_path_a_just_type
        callback_codex_write_draft
        callback_codex_edit
        callback_codex_cancel
        callback_findings_accept_all
        callback_findings_reject_all
        callback_idea_project_new
        free_text_answer
        unauthorized
        unknown
      ].freeze

      Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                          :project, :slug, :question_n, :answer_text, :mode,
                          :intent, keyword_init: true)

      ALLOWED_ACTIONS = %i[
        noop reply dispatch_then_reply dispatch_commands start_answer
        write_answer_then_reply start_codex confirm_codex_draft
      ].freeze

      UNAUTHORIZED_LOG_TTL_SEC = 3600
      PENDING_IDEA_TTL_SEC = 900

      def initialize(bot_config:, logger:, conversation_store:,
                     projects_provider: -> { Hive::Config.registered_projects },
                     now: -> { Time.now })
        @bot_config = bot_config
        @logger = logger
        @conversation_store = conversation_store
        @projects_provider = projects_provider
        @now = now
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
          result_class: Result,
          logger: @logger
        )
        @free_text_handler = Handlers::FreeTextHandler.new(
          conversation_store: @conversation_store,
          result_class: Result
        )
      end

      def classify(update)
        prune_pending_ideas!
        prune_unauthorized_log!
        return :unauthorized unless authorized?(update.chat_id)

        if update.callback_query?
          data = Hive::Bot::NotificationBuilders.resolve_callback(update.callback_data.to_s)
          update = update.with(callback_data: data) if update.respond_to?(:with)
          return callback_intent(data)
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
          @conversation_store.get(chat_id: update.chat_id) || reattach_target(update) ? :free_text_answer : :unknown
        end
      end

      def handle(update)
        if update.callback_query?
          data = Hive::Bot::NotificationBuilders.resolve_callback(update.callback_data.to_s)
          update = update.with(callback_data: data) if update.respond_to?(:with)
        end
        intent = classify(update)
        raise "Router produced unknown intent #{intent.inspect}" unless INTENTS.include?(intent)

        @logger.event(:update_received, update_id: update.update_id,
                                        chat_id: update.chat_id,
                                        intent: intent.to_s) unless intent == :unauthorized
        result = dispatch(intent, update)
        raise "Router result action #{result.action.inspect} is not allowed" unless ALLOWED_ACTIONS.include?(result.action)

        result.intent = intent
        result
      end

      private

      def authorized?(chat_id)
        return true if allowed_chat_ids.include?(chat_id)

        unless @unauthorized_logged[chat_id]
          @logger.event(:update_rejected_unauthorized, chat_id: chat_id)
        end
        @unauthorized_logged[chat_id] = @now.call
        false
      end

      def allowed_chat_ids
        current_allowed = Array(@bot_config.fetch("chat_id_allowlist"))
        if @allowed_chat_ids.nil? || @allowed_chat_ids_source != current_allowed
          @allowed_chat_ids_source = current_allowed.dup
          @allowed_chat_ids = current_allowed.to_set
        end
        @allowed_chat_ids
      end

      def prune_pending_ideas!
        cutoff = @now.call - PENDING_IDEA_TTL_SEC
        @pending_ideas.delete_if { |_token, entry| entry.is_a?(Hash) && entry[:created_at] < cutoff }
      end

      def prune_unauthorized_log!
        # R3 is "once per chat per bot lifetime". Keep the set bounded only
        # by process lifetime; do not prune hostile probes back into logging.
      end

      def callback_intent(data)
        case data
        when /\Aapprove:/ then :callback_approve
        when /\Areject:/ then :callback_reject
        when /\Aclear_retry:/ then :callback_clear_and_retry
        when /\Aopen_laptop:/ then :callback_open_laptop
        when /\Adetails:/ then :callback_show_details
        when /\Arefresh_diagnose:/ then :callback_refresh_diagnose
        when /\Aanswer:/ then :callback_answer
        when /\Aidea_project:/ then :callback_idea_project_pick
        when /\Apath_a_yes:/ then :callback_path_a_yes
        when /\Apath_a_type:/ then :callback_path_a_just_type
        when /\Acodex_write:/ then :callback_codex_write_draft
        when /\Acodex_edit:/ then :callback_codex_edit
        when /\Acodex_cancel:/ then :callback_codex_cancel
        when /\Afindings:accept_all:/ then :callback_findings_accept_all
        when /\Afindings:reject_all:/ then :callback_findings_reject_all
        when /\Aidea_project_new:/ then :callback_idea_project_new
        else :unknown
        end
      end

      def reattach_target(update)
        reply_text = update.respond_to?(:reply_to_text) ? update.reply_to_text.to_s : ""
        return nil if reply_text.empty?

        reply_text.match(%r{(?:\A|\s)(?<project>[A-Za-z0-9_.-]+)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])\s*\(}) ||
          reply_text.match(/\AAnswer mode started for (?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])\./)
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
