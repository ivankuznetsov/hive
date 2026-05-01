module Hive
  module Stages
    module Inbox
      module_function

      # 1-inbox is an inert capture zone — the user must `mv` the task into
      # 2-brainstorm before any agent will run on it. Raising WrongStage
      # gives agent callers a distinct exit code (4) so they can branch on
      # "wrong stage" without parsing stderr.
      def run!(task, _cfg)
        target = File.join(task.hive_state_path, "stages", "2-brainstorm")
        raise Hive::WrongStage.new(
          "1-inbox/ is an inert capture zone. To start work: " \
          "mv #{task.folder} #{target}/ && hive run #{File.join(target, task.slug)}",
          current_stage: "1-inbox",
          target_stage: "2-brainstorm"
        )
      end
    end
  end
end
