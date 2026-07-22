require "hive"
require "hive/execute_waiting_action"
require "hive/markers"

module Hive
  module Conditions
    # Turns the first blocking gate diagnostic into the same agent-callable
    # recovery envelope used by status, transition errors, the TUI, and bots.
    module RecoveryAction
      module_function

      def build(task:, gate:, rerun_with: nil)
        diagnostic = diagnostics(gate).first
        return nil unless diagnostic

        if %w[pending missing].include?(diagnostic["state"])
          return {
            "kind" => Hive::Schemas::NextActionKind::NO_OP,
            "reason" => "condition_reconciliation_required",
            "condition" => diagnostic["condition"],
            "condition_state" => diagnostic["state"],
            "diagnostic_code" => diagnostic["code"],
            "instructions" => "condition evidence is not current yet; re-read `hive status --json` " \
                              "after the execute reconciler or daemon publishes a new observation"
          }
        end

        marker = Hive::Markers::State.new(
          name: :execute_waiting,
          attrs: {
            "reason" => diagnostic["reason"],
            "condition" => diagnostic["condition"],
            "condition_state" => diagnostic["state"]
          },
          raw: nil
        )
        Hive::ExecuteWaitingAction.build(task, marker, rerun_with: rerun_with).merge(
          "reason" => diagnostic["reason"],
          "condition" => diagnostic["condition"],
          "condition_state" => diagnostic["state"],
          "diagnostic_code" => diagnostic["code"]
        )
      end

      def diagnostics(gate)
        if gate.respond_to?(:diagnostics)
          gate.diagnostics
        else
          gate.fetch("diagnostics", [])
        end
      end
    end
  end
end
