require "hive/plan_review/store"
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
        case Array(argv)[1].to_s
        when "plan-review-run"
          folder = task.respond_to?(:folder) && task.folder ?
            task.folder : File.dirname(task.state_file)
          Hive::CanonicalJSON.digest(
            "artifact" => fallback,
            "command" => "plan-review-run",
            "owner_progress" => Hive::PlanReview::Store.new(
              task_folder: folder
            ).progress_token
          )
        else
          fallback
        end
      end
    end
  end
end
