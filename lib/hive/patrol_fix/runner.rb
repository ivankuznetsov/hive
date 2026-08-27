require "hive/patrol_fix"

module Hive
  module PatrolFix
    # Stable first-party dispatch seam. Generic workflow agents never own
    # these stages; the controller loads the closed first-party handler set.
    module Runner
      module_function

      STAGE_FILES = {
        "inbox" => "hive/stages/patrol_fix/inbox",
        "fix" => "hive/stages/patrol_fix/fix",
        "validate" => "hive/stages/patrol_fix/validate",
        "review" => "hive/stages/patrol_fix/review",
        "publish" => "hive/stages/patrol_fix/publish"
      }.freeze

      def run!(task, cfg = nil, **kwargs)
        require "hive/patrol_fix/transition"
        recovered = Hive::PatrolFix::Transition.new(task).reconcile!
        if recovered.is_a?(Hash) && recovered[:task_folder] &&
           task.respond_to?(:folder) && recovered[:task_folder] != task.folder
          return {
            status: :complete, commit: nil,
            moved_task_folder: recovered.fetch(:task_folder)
          }
        end
        handler = load_handler(task.stage_name)
        unless handler
          raise Hive::StageError,
                "patrol-fix controller for stage #{task.stage_name} is not available"
        end

        handler.call(task, cfg || {}, **kwargs)
      end

      def load_handler(stage)
        file = STAGE_FILES[stage.to_s]
        return unless file

        require file
        constant = {
          "inbox" => :Inbox, "fix" => :Fix, "validate" => :Validate,
          "review" => :Review, "publish" => :Publish
        }.fetch(stage.to_s)
        Hive::Stages::PatrolFix.const_get(constant).method(:run!)
      end
      private_class_method :load_handler
    end
  end
end
