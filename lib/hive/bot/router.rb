require "securerandom"
require "set"
require "time"
require "hive/config"
require "hive/bot/notification_builders"
require "hive/bot/idea_draft_store"
require "hive/bot/idea_attachment_policy"
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
        slash_autofix
        slash_details
        slash_done
        slash_help
        slash_start
        callback_approve
        callback_approve_plan
        callback_rerun
        callback_reject
        callback_autofix
        callback_clear_and_retry
        callback_open_laptop
        callback_show_details
        callback_refresh_diagnose
        callback_answer
        callback_idea_project_pick
        callback_idea_voice_confirm
        callback_idea_voice_discard
        callback_idea_done
        callback_idea_skip
        callback_path_a_yes
        callback_path_a_just_type
        callback_findings_accept_all
        callback_findings_reject_all
        callback_idea_project_new
        idea_voice
        idea_voice_during_draft
        idea_voice_edit_text
        answer_voice
        idea_media
        idea_text_capture
        free_text_answer
        unauthorized
        unknown
      ].freeze

      Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                          :project, :slug, :question_n, :answer_text, :mode,
                          :intent, :alert_reset, :clear_keyboard, :format,
                          :attachment, keyword_init: true)

      ALLOWED_ACTIONS = %i[
        noop reply dispatch_then_reply dispatch_commands start_answer
        write_answer_then_reply
        stage_attachment transcribe_voice commit_idea
      ].freeze

      UNAUTHORIZED_LOG_TTL_SEC = 3600
      PENDING_IDEA_TTL_SEC = 900

      def initialize(bot_config:, logger:, conversation_store:, idea_draft_store: nil,
                     projects_provider: -> { Hive::Config.registered_projects },
                     now: -> { Time.now },
                     status_snapshot_provider: -> { [] })
        @bot_config = bot_config
        @logger = logger
        @conversation_store = conversation_store
        @now = now
        @idea_draft_store = idea_draft_store ||
          Hive::Bot::IdeaDraftStore.new(ttl_sec: bot_config.fetch("idea_draft_ttl_sec", PENDING_IDEA_TTL_SEC),
                                        now: @now, logger: @logger)
        @projects_provider = projects_provider
        @unauthorized_logged = {}
        @pending_ideas = {}
        @last_project = nil

        @slash_handlers = Handlers::SlashHandlers.new(
          projects_provider: @projects_provider,
          pending_ideas: @pending_ideas,
          last_project: -> { @last_project },
          result_class: Result,
          idea_draft_store: @idea_draft_store,
          idea_attachment_policy: Hive::Bot::IdeaAttachmentPolicy,
          max_attachment_bytes: bot_config.fetch("idea_attachment_max_bytes", 20 * 1024 * 1024),
          max_attachment_count: bot_config.fetch("idea_attachment_max_count", 10),
          status_snapshot_provider: status_snapshot_provider
        )
        @callback_handlers = Handlers::CallbackHandlers.new(
          pending_ideas: @pending_ideas,
          set_last_project: ->(project) { @last_project = project },
          conversation_store: @conversation_store,
          result_class: Result,
          idea_draft_store: @idea_draft_store,
          projects_provider: @projects_provider,
          last_project: -> { @last_project },
          logger: @logger,
          status_snapshot_provider: status_snapshot_provider
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

        text = effective_text(update).to_s.strip
        case text
        when %r{\A/status\b} then :slash_status
        when %r{\A/queue\b} then :slash_queue
        when %r{\A/idea\b} then :slash_idea
        when %r{\A/answer\b} then :slash_answer
        when %r{\A/approve\b} then :slash_approve
        when %r{\A/autofix\b} then :slash_autofix
        when %r{\A/details\b} then :slash_details
        when %r{\A/done\b} then :slash_done
        when %r{\A/help\b} then :slash_help
        # Telegram sends /start automatically on first contact with a bot —
        # the universal hello. Falling through to "I did not understand
        # that" greeted every new operator with a shrug.
        when %r{\A/start\b} then :slash_start
        else
          if answer_context(update)
            return :answer_voice if update.respond_to?(:voice?) && update.voice?

            return :free_text_answer
          end
          draft = @idea_draft_store.get(chat_id: update.chat_id)
          if draft&.phase == :awaiting_transcript_confirm && draft.origin == :voice
            return :idea_voice if update.respond_to?(:voice?) && update.voice?
            return :idea_voice_edit_text if update.respond_to?(:text?) && update.text?
          end
          if update.respond_to?(:voice?) && update.voice?
            return :idea_voice_during_draft if draft && draft.origin != :voice

            return :idea_voice
          end
          return :idea_media if update.respond_to?(:media?) && update.media?
          return :idea_text_capture if draft&.phase == :awaiting_text

          :unknown
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
        @idea_draft_store.prune! if @idea_draft_store
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
        when /\Aapprove_plan:/ then :callback_approve_plan
        when /\Arerun:/ then :callback_rerun
        when /\Areject:/ then :callback_reject
        when /\Aautofix:/ then :callback_autofix
        when /\Aclear_retry:/ then :callback_clear_and_retry
        when /\Aopen_laptop:/ then :callback_open_laptop
        when /\Adetails:/ then :callback_show_details
        when /\Arefresh_diagnose:/ then :callback_refresh_diagnose
        when /\Aanswer:/ then :callback_answer
        when /\Aidea_project:/ then :callback_idea_project_pick
        when /\Aidea_voice_confirm:/ then :callback_idea_voice_confirm
        when /\Aidea_voice_discard:/ then :callback_idea_voice_discard
        when /\Aidea_done:/ then :callback_idea_done
        when /\Aidea_skip:/ then :callback_idea_skip
        when /\Apath_a_yes:/ then :callback_path_a_yes
        when /\Apath_a_type:/ then :callback_path_a_just_type
        when /\Afindings:accept_all:/ then :callback_findings_accept_all
        when /\Afindings:reject_all:/ then :callback_findings_reject_all
        when /\Aidea_project_new:/ then :callback_idea_project_new
        else :unknown
        end
      end

      def reattach_target(update)
        reply_text = update.respond_to?(:reply_to_text) ? update.reply_to_text.to_s : ""
        return nil if reply_text.empty?

        if (match = reply_text.match(%r{(?:\A|\s)(?<project>[A-Za-z0-9_.-]+)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])\s*\(}))
          return { project: match[:project], slug: match[:slug] }
        end

        if (match = reply_text.match(/\AAnswer mode started for (?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])\./))
          return { project: nil, slug: match[:slug] }
        end

        nil
      end

      def answer_context(update)
        state = @conversation_store.get(chat_id: update.chat_id)
        if state
          return {
            project: state.project,
            slug: state.slug,
            question_n: state.question_n,
            mode: state.mode
          }
        end

        reattached = reattach_target(update)
        return nil unless reattached

        {
          project: reattached[:project],
          slug: reattached.fetch(:slug),
          question_n: nil,
          mode: :path_b
        }
      end

      def effective_text(update)
        update.respond_to?(:effective_text) ? update.effective_text : update.text
      end

      def dispatch(intent, update)
        case intent
        when :unauthorized then Result.new(action: :noop)
        when :slash_status then @slash_handlers.status(update)
        when :slash_queue then @slash_handlers.queue(update)
        when :slash_idea then @slash_handlers.idea(update)
        when :slash_answer then @slash_handlers.answer(update, @conversation_store)
        when :slash_approve then @slash_handlers.approve(update)
        when :slash_autofix then @slash_handlers.autofix(update)
        when :slash_details then @slash_handlers.details(update)
        when :slash_done then @slash_handlers.done(update, @conversation_store)
        when :slash_help then @slash_handlers.help(update)
        when :slash_start then @slash_handlers.start(update)
        when :idea_voice then @slash_handlers.voice(update)
        when :answer_voice then answer_voice(update)
        when :idea_voice_during_draft then Result.new(action: :reply, text: Hive::Bot::IdeaDraftStore::VOICE_DURING_DRAFT_MESSAGE)
        when :idea_voice_edit_text then @slash_handlers.edit_transcript_text(update)
        when :idea_media then @slash_handlers.media(update)
        when :idea_text_capture then @slash_handlers.capture_idea_text(update)
        when :free_text_answer then @free_text_handler.handle(update)
        when :unknown then Result.new(action: :reply, text: "I did not understand that. Send /help for commands.")
        else @callback_handlers.handle(intent, update)
        end
      end

      def answer_voice(update)
        context = answer_context(update)
        return Result.new(action: :reply, text: "Send /answer <slug> before sending a voice answer.") unless context

        result = @slash_handlers.voice(update)
        return result unless result.action == :transcribe_voice

        result.project = context[:project]
        result.slug = context.fetch(:slug)
        result.question_n = context[:question_n]
        result.mode = context[:mode] || :path_b
        result.attachment = result.attachment.merge(purpose: :answer)
        result
      end
    end
  end
end
