require "hive/stages/base"

module Hive
  module Stages
    module Brainstorm
      module_function

      def run!(task, cfg)
        idea_path = File.join(task.folder, "idea.md")
        idea_text = File.exist?(idea_path) ? File.read(idea_path) : ""
        prompt = Hive::Stages::Base.render(
          "brainstorm_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            idea_text: idea_text,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
        # add_dirs is intentionally limited to the task folder. Brainstorm
        # operates on user-supplied idea text and must not have write access
        # to the project source code (claude runs with
        # --dangerously-skip-permissions; widening add-dir would let a
        # prompt-injected idea reach project files).
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", "brainstorm"),
          timeout_sec: cfg.dig("timeout_sec", "brainstorm"),
          log_label: "brainstorm"
        )
        marker = Hive::Markers.current(task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      def action_for(marker_name)
        case marker_name
        when :waiting then "round_waiting"
        when :complete then "complete"
        when :error then "error"
        else marker_name.to_s
        end
      end
    end
  end
end
