require "hive/canonical_json"

module Hive
  module Attempts
    # Command owners may contribute a semantic progress token when their state
    # advances independently of the task artifact. The generic dispatcher
    # asks this interface instead of knowing plan-review file layout or
    # special-casing current.json bytes itself.
    module CommandProgress
      module_function

      def token_for(argv:, task:, fallback:)
        return task_token_for(task: task, fallback: fallback) if task_progress?(task)

        case Array(argv)[1].to_s
        when "plan-review-run"
          require "hive/plan_review/store"
          Hive::CanonicalJSON.digest(
            "artifact" => fallback,
            "command" => "plan-review-run",
            "owner_progress" => Hive::PlanReview::Store.new(
              task_folder: task_folder(task)
            ).progress_token
          )
        else
          fallback
        end
      end

      def task_progress?(task)
        patrol_fix?(task)
      end

      def task_token_for(task:, fallback:)
        return fallback unless task_progress?(task)

        patrol_fix_token(task, fallback)
      end

      def patrol_fix?(task)
        return false unless task.respond_to?(:workflow)

        workflow = task.workflow
        workflow.respond_to?(:controller) && workflow.controller == :patrol_fix
      end

      def patrol_fix_token(task, fallback)
        require "hive/patrol_fix/receipt_store"
        Hive::CanonicalJSON.digest(
          "artifact" => fallback,
          "workflow" => "patrol-fix",
          "owner_progress" => Hive::PatrolFix::ReceiptStore.new(
            task_folder: task_folder(task)
          ).progress_token
        )
      end

      def task_folder(task)
        task.respond_to?(:folder) && task.folder ? task.folder : File.dirname(task.state_file)
      end
    end
  end
end
