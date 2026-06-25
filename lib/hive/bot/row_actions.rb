require "hive"
require "hive/workflows"
# RowActions and NotificationBuilders are mutually recursive at runtime
# (RowActions.resolve calls the recovery/verb predicates below;
# NotificationBuilders.needs_input calls RowActions.resolve). Declaring the
# require here makes `require "hive/bot/row_actions"` self-sufficient — without
# it, resolving a recovery row in isolation raised NameError. Neither file
# references the other at load time, so the require cycle is safe.
require "hive/bot/notification_builders"

module Hive
  module Bot
    module RowActions
      module_function

      # The closed surface vocabulary the bot dispatches on. One kind per
      # needs_input notification builder, plus the non-needs_input outcomes
      # (stage approval, recovery) and the empty/suppressed cases. Carrying
      # the kind on the Resolution lets NotificationBuilders switch on intent
      # directly instead of reverse-engineering it from the exact role array
      # — which silently mis-routed to the neutral default when an action was
      # reordered or added.
      KINDS = %i[
        none suppressed brainstorm_waiting plan_waiting review_waiting
        execute_waiting finalize_waiting generic_needs_input stage_approval
        recovery
      ].freeze

      Resolution = Data.define(:actions, :kind) do
        def initialize(actions: [], kind: :none)
          unless KINDS.include?(kind)
            raise ArgumentError, "unknown resolution kind #{kind.inspect} (expected one of #{KINDS.inspect})"
          end

          primaries = actions.count(&:primary)
          if !actions.empty? && primaries != 1
            raise ArgumentError,
                  "resolution must declare exactly one primary action, got #{primaries} (kind=#{kind.inspect})"
          end

          super(actions: actions.freeze, kind: kind)
        end

        # True when this row should push no notification and render no button.
        # Derived from the kind so the suppressed state has a single
        # representation — a separate `suppress` flag could drift into a
        # contradictory `(suppress: true, kind: :plan_waiting)` pair.
        def suppress
          kind == :suppressed
        end

        # The action the bot renders as the primary keyboard button / status
        # hint. Construction guarantees exactly one primary for a non-empty
        # resolution, so this is unambiguous; an empty resolution has none.
        def primary
          actions.find(&:primary)
        end
      end

      # The closed role vocabulary. Every consumer keys off these
      # (NotificationBuilders.label_for_action, Supervisor#status_action_emoji,
      # #next_step_hint), so validating at construction turns a typo'd or
      # newly-added role into a clear boundary error here instead of a deep
      # Hash#fetch KeyError in one of those tables.
      ROLES = %i[
        answer approve approve_plan findings_accept findings_reject
        rerun autofix details
      ].freeze

      Action = Data.define(:role, :callback, :primary, :verb) do
        def initialize(role:, callback:, primary: false, verb: nil)
          unless ROLES.include?(role)
            raise ArgumentError, "unknown action role #{role.inspect} (expected one of #{ROLES.inspect})"
          end
          if callback.nil? || callback.to_s.empty?
            raise ArgumentError, "action #{role.inspect} requires a callback"
          end
          # `:rerun` renders a verb-derived label/hint ("Re-run develop" /
          # "Run finalize"); a nil verb would render "tap Re-run to re-run ."
          if role == :rerun && (verb.nil? || verb.to_s.empty?)
            raise ArgumentError, "action :rerun requires a verb (the workflow verb to re-run)"
          end

          super
        end
      end

      def resolve(row)
        return Resolution.new(kind: :suppressed) if suppressed_needs_input?(row)

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
          return coding_brainstorm_waiting(row) if coding_stage?(row, "2-brainstorm") # coding-scoped: brainstorm Q&A answer flow is coding-only
          return coding_plan_waiting(row) if coding_stage?(row, "3-plan") # coding-scoped: plan-approval pause only exists in coding workflow
        elsif marker == "review_waiting"
          return review_waiting(row)
        elsif marker == "execute_waiting"
          return with_details(row, action(:rerun, rerun_callback(row, "develop"), primary: true, verb: "develop"),
                              kind: :execute_waiting)
        end

        if coding_stage?(row, "8-finalize") # coding-scoped: coding finalize stage re-run pause
          return with_details(row, action(:rerun, rerun_callback(row, "finalize"), primary: true, verb: "finalize"),
                              kind: :finalize_waiting)
        end

        Resolution.new(actions: [ action(:rerun, rerun_callback(row, "run"), primary: true, verb: "run") ],
                       kind: :generic_needs_input)
      end

      def coding_brainstorm_waiting(row)
        Resolution.new(actions: [ action(:answer, "answer:#{row.project}:#{row.slug}", primary: true) ],
                       kind: :brainstorm_waiting)
      end

      def coding_plan_waiting(row)
        with_details(row, action(:approve_plan, approve_plan_callback(row), primary: true), kind: :plan_waiting)
      end

      def review_waiting(row)
        if attrs(row)["reason"].to_s == "fix_guardrail"
          return Resolution.new(
            actions: [ action(:details, notification_builders.details_callback(row), primary: true) ],
            kind: :review_waiting
          )
        end

        Resolution.new(actions: [
          action(:findings_accept, "findings:accept_all:#{row.project}:#{row.slug}:#{row.stage}", primary: true),
          action(:findings_reject, "findings:reject_all:#{row.project}:#{row.slug}:#{row.stage}"),
          action(:details, notification_builders.details_callback(row))
        ], kind: :review_waiting)
      end

      def ready_actions(row)
        verb = notification_builders.verb_for_action(row.action)
        return Resolution.new unless verb

        Resolution.new(actions: [
          action(:approve, "approve:#{verb}:#{row.project}:#{row.slug}:#{row.stage}", primary: true)
        ], kind: :stage_approval)
      end

      def recovery_actions(row)
        if notification_builders.retryable_recovery?(row)
          Resolution.new(actions: [ action(:autofix, notification_builders.autofix_callback(row), primary: true) ],
                         kind: :recovery)
        else
          Resolution.new(actions: [ action(:details, notification_builders.details_callback(row), primary: true) ],
                         kind: :recovery)
        end
      end

      def with_details(row, primary_action, kind:)
        Resolution.new(actions: [
          primary_action,
          action(:details, notification_builders.details_callback(row))
        ], kind: kind)
      end

      def action(role, callback, primary: false, verb: nil)
        Action.new(role: role, callback: callback, primary: primary, verb: verb)
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

      # `verb_for_action` is the single source of truth for "this ready_to_X
      # row maps to an Approve button" — a row is ready-actionable iff it has
      # a workflow verb. (Every ready row's role is uniformly `:approve`, so
      # there is no separate role table to keep in sync.)
      def ready_action?(row)
        !notification_builders.verb_for_action(row.action).nil?
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
