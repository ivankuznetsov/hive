require "digest"
require "json"
require "hive"

module Hive
  module Bot
    module NotificationBuilders
      module_function

      READY_ACTIONS = %w[
        ready_to_brainstorm
        ready_to_plan
        ready_to_develop
        ready_for_review
        ready_for_pr
        ready_to_archive
      ].freeze

      INPUT_ACTIONS = %w[
        needs_input
        recover_execute
        recover_review
        error
      ].freeze

      SKIP_ACTIONS = %w[
        agent_running
        archived
        review_findings
      ].freeze

      def build(row)
        if READY_ACTIONS.include?(row.action)
          stage_approval(row)
        elsif row.action == Hive::Schemas::TaskActionKind::NEEDS_INPUT
          needs_input(row)
        elsif recovery?(row)
          recovery(row)
        else
          nil
        end
      end

      def fingerprint(row)
        attrs = row.attrs.to_a.sort_by(&:first)
        Digest::SHA256.hexdigest(JSON.generate([ row.project, row.slug, row.marker, attrs ]))
      end

      def recovery?(row)
        %w[recover_execute recover_review error].include?(row.action) ||
          %w[review_error review_stale review_ci_stale execute_stale error].include?(row.marker)
      end

      def stage_approval(row)
        verb = verb_for_action(row.action)
        return nil unless verb

        Notification.new(
          text: header(row) + "\nReady for #{verb}.",
          keyboard: [
            [ button("Approve", "approve:#{verb}:#{row.project}:#{row.slug}:#{row.stage}") ],
            [ button("Reject", "reject:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def needs_input(row)
        case row.marker
        when "waiting"
          brainstorm_waiting(row)
        when "review_waiting"
          review_waiting(row)
        else
          Notification.new(
            text: header(row) + "\nNeeds input: #{marker_with_attrs(row)}",
            keyboard: [
              [ button("Show details", "details:#{row.project}:#{row.slug}") ],
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ]
            ]
          )
        end
      end

      def brainstorm_waiting(row)
        Notification.new(
          text: header(row) + "\nBrainstorm questions are waiting.",
          keyboard: [
            [ button("Answer in chat", "answer:#{row.project}:#{row.slug}") ],
            [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def review_waiting(row)
        if row.attrs["reason"] == "fix_guardrail"
          return recovery(row)
        end

        Notification.new(
          text: header(row) + "\nReview triage is waiting.",
          keyboard: [
            [
              button("Accept all", "findings:accept_all:#{row.project}:#{row.slug}:#{row.stage}"),
              button("Reject all", "findings:reject_all:#{row.project}:#{row.slug}:#{row.stage}")
            ],
            [ button("Show details", "details:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def recovery(row)
        Notification.new(
          text: header(row) + "\nNeeds recovery: #{marker_with_attrs(row)}",
          keyboard: [
            [ button("Clear and retry", "clear_retry:#{row.project}:#{row.slug}:#{row.stage}:#{row.marker}") ],
            [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
            [ button("Show details", "details:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def header(row)
        "#{row.project}/#{row.slug} (#{row.stage})"
      end

      def marker_with_attrs(row)
        attrs = row.attrs.to_a.sort_by(&:first).map { |key, value| "#{key}=#{value}" }.join(" ")
        attrs.empty? ? row.marker : "#{row.marker} #{attrs}"
      end

      def verb_for_action(action)
        {
          "ready_to_brainstorm" => "brainstorm",
          "ready_to_plan" => "plan",
          "ready_to_develop" => "develop",
          "ready_for_review" => "review",
          "ready_for_pr" => "pr",
          "ready_to_archive" => "archive"
        }[action]
      end

      def button(text, callback_data)
        { text: text, callback_data: callback_data }
      end

      Notification = Struct.new(:text, :keyboard, keyword_init: true)
    end
  end
end
