require "digest"
require "json"
require "hive/bot/notification_builders"

module Hive
  module Eval
    class ReasonClassifier
      ALLOW_LIST = %w[
        agent_blocked_question
        status_response
        task_finished
        fatal_error
      ].freeze
      UNCLASSIFIED = "UNCLASSIFIED"

      Classification = Struct.new(:message, :reason, :proactive, :detail, keyword_init: true)

      ERROR_MARKERS = %w[
        error
        review_error
        review_stale
        review_ci_stale
        execute_stale
      ].freeze

      STATUS_INTENTS = %i[
        slash_status
        slash_queue
        callback_show_details
        callback_refresh_diagnose
        slash_help
        slash_idea
        callback_idea_project_pick
        callback_idea_project_new
        callback_idea_done
        callback_idea_skip
        callback_open_laptop
        callback_reject
        unknown
      ].freeze

      COMMAND_ACK_INTENTS = %i[
        slash_approve
        slash_done
        callback_approve
        callback_clear_and_retry
        callback_findings_accept_all
        callback_findings_reject_all
      ].freeze

      ANSWER_INTENTS = %i[
        slash_answer
        callback_answer
        callback_path_a_yes
        callback_path_a_just_type
        callback_codex_write_draft
        callback_codex_edit
        callback_codex_cancel
        free_text_answer
      ].freeze

      def initialize(messages:, log_events: [])
        @messages = messages
        @log_events = log_events
      end

      def classify_all
        @messages.map { |message| classify(message) }
      end

      def classify(message)
        if message.row
          reason, detail = classify_row(message.row)
          return classification(message, reason, proactive: true, detail: detail)
        end

        if message.source == :handler && message.intent
          reason, detail = classify_handler(message.intent, message.text)
          return classification(message, reason, proactive: false, detail: detail)
        end

        if message.source == :child
          reason = message.child&.exit_code.to_i.zero? ? "task_finished" : "fatal_error"
          return classification(message, reason, proactive: false, detail: "child_exit")
        end

        reason, detail = classify_text(message.text)
        classification(message, reason, proactive: false, detail: detail)
      end

      private

      def classification(message, reason, proactive:, detail:)
        Classification.new(
          message: message,
          reason: reason || UNCLASSIFIED,
          proactive: proactive,
          detail: detail
        )
      end

      def classify_row(row)
        action = row.action.to_s
        marker = row.marker.to_s
        if action == "error" || ERROR_MARKERS.include?(marker)
          return [ "fatal_error", "row action=#{action.inspect} marker=#{marker.inspect}" ]
        end

        if Hive::Bot::NotificationBuilders::INPUT_ACTIONS.include?(action)
          return [ "agent_blocked_question", "row action=#{action.inspect} marker=#{marker.inspect}" ]
        end

        if Hive::Bot::NotificationBuilders::READY_ACTIONS.include?(action)
          return [ "task_finished", "row action=#{action.inspect} marker=#{marker.inspect}" ]
        end

        [ UNCLASSIFIED, "no row mapping for action=#{action.inspect} marker=#{marker.inspect}" ]
      end

      def classify_handler(intent, text)
        intent = intent.to_sym
        return [ "status_response", "handler intent=#{intent}" ] if STATUS_INTENTS.include?(intent)
        return [ "status_response", "handler command ack intent=#{intent}" ] if COMMAND_ACK_INTENTS.include?(intent)
        return [ classify_answer_text(text), "handler answer intent=#{intent}" ] if ANSWER_INTENTS.include?(intent)

        [ UNCLASSIFIED, "no handler mapping for intent=#{intent}" ]
      end

      def classify_answer_text(text)
        body = text.to_s
        return "fatal_error" if body.match?(/failed|not found|already answered|lock|confused/i)
        # "Reply with your answer" is the new Q-by-Q prompt format introduced by
        # the answer-flow cleanup; legacy prompts ("Answer mode started", etc)
        # are kept for any older code paths that may still route here.
        return "agent_blocked_question" if body.match?(/Reply with your answer|Answer mode started|Send the answer|Codex draft/i)

        "status_response"
      end

      def classify_text(text)
        body = text.to_s
        return [ "task_finished", "text fallback" ] if body.match?(/Command completed|Already advanced/i)
        return [ "fatal_error", "text fallback" ] if body.match?(/failed|error|confused|Try again|Stopped/i)
        return [ "status_response", "text fallback" ] if body.match?(/active task|No active Hive tasks|Action:/i)

        [ UNCLASSIFIED, "no text fallback" ]
      end
    end
  end
end
