require "hive"
require "hive/workflows"

module Hive
  module Bot
    module RowActions
      module_function

      Resolution = Data.define(:actions, :suppress) do
        def initialize(actions: [], suppress: false)
          super(actions: actions.freeze, suppress: suppress)
        end
      end

      Action = Data.define(:role, :callback, :primary) do
        def initialize(role:, callback:, primary: false)
          super
        end
      end

      READY_ROLES = {
        "ready_to_brainstorm" => :approve,
        "ready_to_plan" => :approve,
        "ready_to_develop" => :approve,
        "ready_to_open_pr" => :approve,
        "ready_for_review" => :approve,
        "ready_to_artifacts" => :approve,
        "ready_to_finalize" => :approve,
        "ready_to_archive" => :approve,
        "ready_to_advance" => :approve,
        "ready_to_run" => :approve
      }.freeze

      def resolve(row)
        return Resolution.new(suppress: true) if suppressed_needs_input?(row)

        if needs_input?(row)
          return needs_input_actions(row)
        elsif ready_action?(row)
          return ready_actions(row)
        elsif notification_builders.recovery?(row)
          return recovery_actions(row)
        end

        Resolution.new
      end

      def suppressed_needs_input?(row)
        return false unless needs_input?(row)

        %w[none complete].include?(marker_name(row))
      end

      def terminal_details?(row)
        return true if notification_builders.manual_only?(marker: row.marker, attrs: row.attrs)

        marker_name(row) == "review_waiting" && attrs(row)["reason"].to_s == "fix_guardrail"
      end

      def needs_input_actions(row)
        marker = marker_name(row)
        if marker == "waiting"
          return coding_brainstorm_waiting(row) if coding_stage?(row, "2-brainstorm")
          return coding_plan_waiting(row) if coding_stage?(row, "3-plan")
        elsif marker == "review_waiting"
          return review_waiting(row)
        elsif marker == "execute_waiting"
          return with_details(row, action(:rerun, rerun_callback(row, "develop"), primary: true))
        end

        if coding_stage?(row, "8-finalize") || coding_stage?(row, "7-finalize")
          return with_details(row, action(:run, rerun_callback(row, "finalize"), primary: true))
        end

        Resolution.new(actions: [ action(:run, rerun_callback(row, "run"), primary: true) ])
      end

      def coding_brainstorm_waiting(row)
        Resolution.new(actions: [ action(:answer, "answer:#{row.project}:#{row.slug}", primary: true) ])
      end

      def coding_plan_waiting(row)
        with_details(row, action(:approve_plan, approve_plan_callback(row), primary: true))
      end

      def review_waiting(row)
        if attrs(row)["reason"].to_s == "fix_guardrail"
          return Resolution.new(actions: [ action(:details, notification_builders.details_callback(row), primary: true) ])
        end

        Resolution.new(actions: [
          action(:findings_accept, "findings:accept_all:#{row.project}:#{row.slug}:#{row.stage}", primary: true),
          action(:findings_reject, "findings:reject_all:#{row.project}:#{row.slug}:#{row.stage}"),
          action(:details, notification_builders.details_callback(row))
        ])
      end

      def ready_actions(row)
        verb = notification_builders.verb_for_action(row.action)
        return Resolution.new unless verb

        Resolution.new(actions: [
          action(READY_ROLES.fetch(row.action.to_s), "approve:#{verb}:#{row.project}:#{row.slug}:#{row.stage}",
                 primary: true)
        ])
      end

      def recovery_actions(row)
        if notification_builders.retryable_recovery?(row)
          Resolution.new(actions: [ action(:autofix, notification_builders.autofix_callback(row), primary: true) ])
        else
          Resolution.new(actions: [ action(:details, notification_builders.details_callback(row), primary: true) ])
        end
      end

      def with_details(row, primary_action)
        Resolution.new(actions: [
          primary_action,
          action(:details, notification_builders.details_callback(row))
        ])
      end

      def action(role, callback, primary: false)
        Action.new(role: role, callback: callback, primary: primary)
      end

      def approve_plan_callback(row)
        "approve_plan:#{row.project}:#{row.slug}:#{row.stage}"
      end

      def rerun_callback(row, verb)
        "rerun:#{row.project}:#{row.slug}:#{row.stage}:#{verb}"
      end

      def needs_input?(row)
        row.action.to_s == Hive::Schemas::TaskActionKind::NEEDS_INPUT
      end

      def ready_action?(row)
        READY_ROLES.key?(row.action.to_s)
      end

      def coding_stage?(row, stage)
        Hive::Workflows.coding_row?(row) && row.stage.to_s == stage
      end

      def marker_name(row)
        row.marker.to_s.downcase
      end

      def attrs(row)
        row.attrs.to_h.transform_keys(&:to_s)
      end

      def notification_builders
        Hive::Bot::NotificationBuilders
      end
    end
  end
end
