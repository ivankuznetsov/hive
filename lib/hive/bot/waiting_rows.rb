require "hive/bot/notification_builders"
require "hive/bot/row_actions"

module Hive
  module Bot
    module WaitingRows
      module_function

      NEEDS_INPUT_KINDS = %i[
        brainstorm_waiting
        plan_waiting
        review_waiting
        execute_waiting
        finalize_waiting
        generic_needs_input
      ].freeze

      URGENCY_RANK = {
        review_waiting: 0,
        brainstorm_waiting: 1,
        plan_waiting: 2,
        execute_waiting: 3,
        finalize_waiting: 3,
        generic_needs_input: 4
      }.freeze

      ROLE_EMOJI = {
        answer: "✏️",
        approve: "✅",
        approve_plan: "✅",
        findings_accept: "✅",
        findings_reject: "🚫",
        autofix: "🔧",
        details: "🔍",
        rerun: "▶️"
      }.freeze

      def select(rows, daemon_enabled:)
        indexed = Array(rows).each_with_index.filter_map do |row, index|
          resolution = resolve(row)
          next unless resolution
          next unless NEEDS_INPUT_KINDS.include?(resolution.kind)
          next if daemon_plan_pause?(row, resolution, daemon_enabled)

          [ row, resolution, index ]
        end

        indexed.sort_by { |_row, resolution, index| [ urgency_rank(resolution.kind), index ] }
               .map(&:first)
      end

      def button_for(row)
        resolution = Hive::Bot::RowActions.resolve(row)
        return nil if resolution.suppress || resolution.actions.empty?

        action = resolution.primary
        nb = Hive::Bot::NotificationBuilders
        nb.button("#{ROLE_EMOJI.fetch(action.role)} #{nb.display_title(row)}", action.callback)
      end

      def resolve(row)
        Hive::Bot::RowActions.resolve(row)
      rescue StandardError
        nil
      end

      def daemon_plan_pause?(row, resolution, daemon_enabled)
        resolution.kind == :plan_waiting && daemon_enabled.call(row)
      rescue StandardError
        false
      end

      def urgency_rank(kind)
        URGENCY_RANK.fetch(kind, URGENCY_RANK.fetch(:generic_needs_input))
      end
    end
  end
end
