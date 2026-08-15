require "hive/config"
require "hive/lock"
require "hive/plan_review/orchestrator"
require "hive/plan_review/projection"
require "hive/plan_review/store"
require "hive/plan_review/transition_guard"
require "hive/workflows"

module Hive
  module PlanReview
    # Non-authority lifecycle entrypoint for daemon/agent automation. It may
    # start or resume review attempts, revisions, and verification, but it has
    # no API for approvals, answers, waivers, or mandatory downgrades.
    module Automation
      module_function

      def run!(task:, config: nil, orchestrator: nil)
        unless Hive::Workflows.coding_id?(task.workflow.id) &&
               task.stage_index == 3 && task.stage_name == "plan"
          raise TransitionBlocked.new(
            "plan review automation applies only to built-in coding tasks at 3-plan",
            current_stage: "#{task.stage_index}-#{task.stage_name}",
            target_stage: TransitionGuard::EXECUTE_STAGE
          )
        end

        projection = nil
        Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "plan-review-automation") do
          cfg = config || Hive::Config.load(task.project_root)
          current = Store.new(task_folder: task.folder).current_validated(optional: true)
          planner_identity = planner_identity_for(current, cfg)
          projection = if orchestrator
            orchestrator.call(task:, cfg:, planner_identity:)
          else
            Orchestrator.run!(task:, cfg:, planner_identity:)
          end
        end
        projection || raise(
          TransitionBlocked.new(
            "plan review could not initialize from the current plan",
            current_stage: TransitionGuard::PLAN_STAGE,
            target_stage: TransitionGuard::EXECUTE_STAGE
          )
        )
      end

      def planner_identity_for(current, cfg)
        route = current && current["routes"].find { |entry| entry["role"] == "planner" }
        route&.fetch("actual", nil) || route&.fetch("requested", nil) ||
          TransitionGuard.reconstructed_planner_identity(cfg)
      end
      private_class_method :planner_identity_for
    end
  end
end
