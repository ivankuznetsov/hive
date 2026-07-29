require "hive/errors"
require "hive/modules/migration/patrol_decision_projection"

module Hive
  module Patrol
    module DecisionProjection
      TRIGGERS = %w[continuous timer new_commits].freeze
      SCHEDULE_KEYS = %w[
        branch_changed enabled kind timer_due trigger
      ].freeze

      module_function

      def schedule_input(enabled:, trigger:, timer_due:, branch_changed:)
        input = {
          "kind" => "schedule",
          "enabled" => enabled,
          "trigger" => trigger.to_s,
          "timer_due" => timer_due,
          "branch_changed" => branch_changed
        }.freeze
        validate_input!(input)
      end

      def module_event_input(event_id)
        validate_input!(
          { "kind" => "module_event", "event_id" => event_id.to_s }.freeze
        )
      end

      def operation_input(operation)
        validate_input!(
          { "kind" => "operation", "operation" => operation.to_s }.freeze
        )
      end

      def project(input)
        input = validate_input!(input)
        rationale = case input.fetch("kind")
        when "schedule"
          schedule_rationale(input)
        when "module_event", "operation"
          "due"
        end
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: rationale
        )
      end

      def validate_input!(input)
        malformed! unless input.is_a?(Hash)
        case input["kind"]
        when "schedule"
          malformed! unless input.keys.sort == SCHEDULE_KEYS &&
                            [ true, false ].include?(input["enabled"]) &&
                            TRIGGERS.include?(input["trigger"]) &&
                            boolean_or_nil?(input["timer_due"]) &&
                            boolean_or_nil?(input["branch_changed"])
        when "module_event"
          malformed! unless input.keys.sort == %w[event_id kind] &&
                            !input["event_id"].to_s.empty?
        when "operation"
          malformed! unless input.keys.sort == %w[kind operation] &&
                            !input["operation"].to_s.empty?
        else
          malformed!
        end
        input
      end

      def schedule_rationale(input)
        return "disabled" unless input.fetch("enabled")

        due = case input.fetch("trigger")
        when "timer"
          input["timer_due"] == true
        when "continuous"
          input["timer_due"] == true ||
            input["branch_changed"] == true
        when "new_commits"
          input["branch_changed"] == true
        end
        due ? "due" : "not_due"
      end
      private_class_method :schedule_rationale

      def boolean_or_nil?(value)
        value.nil? || value == true || value == false
      end
      private_class_method :boolean_or_nil?

      def malformed!
        raise Hive::ConfigError,
              "ordinary patrol selection input is malformed"
      end
      private_class_method :malformed!
    end
  end
end
