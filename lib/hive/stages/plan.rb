require "hive/stages/base"

module Hive
  module Stages
    module Plan
      module_function

      def run!(task, cfg)
        brainstorm_path = File.join(task.folder, "brainstorm.md")
        brainstorm_text = File.exist?(brainstorm_path) ? File.read(brainstorm_path) : ""
        prompt = Hive::Stages::Base.render(
          "plan_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            brainstorm_text: brainstorm_text,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
        # See brainstorm.rb: add-dir narrowed to the task folder so a
        # prompt-injected brainstorm.md cannot reach the project source.
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [task.folder],
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", "plan"),
          timeout_sec: cfg.dig("timeout_sec", "plan"),
          log_label: "plan"
        )
        marker = Hive::Markers.current(task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      def action_for(marker_name)
        case marker_name
        when :waiting then "draft_updated"
        when :complete then "complete"
        when :error then "error"
        else marker_name.to_s
        end
      end
    end
  end
end
