require "hive/stages/base"
require "hive/claude_launcher"

module Hive
  module Stages
    module Plan
      module_function

      def run!(task, cfg)
        brainstorm_path = File.join(task.folder, "brainstorm.md")
        brainstorm_text = File.exist?(brainstorm_path) ? File.read(brainstorm_path) : ""
        profile = Hive::Stages::Base.stage_profile(cfg, "plan")
        skill = Hive::Config.stage_skill(cfg, "plan")
        prompt = Hive::Stages::Base.render(
          "plan_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            brainstorm_text: brainstorm_text,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            skill_invocation: profile.format_skill_invocation(skill)
          )
        )
        # See brainstorm.rb: add-dir narrowed to the task folder so a
        # prompt-injected brainstorm.md cannot reach the project source.
        spawn_plan_agent(task, cfg, prompt, profile)
        marker = Hive::Markers.current(task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      def spawn_plan_agent(task, cfg, prompt, profile)
        scope = Hive::Stages::Base.stage_permission_scope(
          cfg, "plan", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
        )
        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", "plan"),
          timeout_sec: cfg.dig("timeout_sec", "plan"),
          log_label: "plan",
          profile: profile,
          permission_mode: scope.fetch(:permission_mode),
          allowed_tools: scope.fetch(:allowed_tools),
          disallowed_tools: scope.fetch(:disallowed_tools),
          status_mode: :state_file_marker
        }
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("3-plan", task) # coding-scoped: coding plan stage tmux session
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
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
