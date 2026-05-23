require "fileutils"
require "hive/claude_launcher"
require "hive/markers"
require "hive/stages/base"

module Hive
  module Stages
    module Artifacts
      module_function

      def run!(task, cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: :complete } if marker.name == :complete

        profile = Hive::Stages::Base.stage_profile(cfg, "artifacts")
        prompt = render_prompt(task)
        spawn_artifacts_agent(task, cfg, prompt, profile)
        marker = Hive::Markers.current(task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      def spawn_artifacts_agent(task, cfg, prompt, profile)
        cwd = File.directory?(task.worktree_path.to_s) ? task.worktree_path : task.folder
        kwargs = {
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: cwd,
          max_budget_usd: cfg.dig("budget_usd", "artifacts") || Hive::Config::DEFAULTS.dig("budget_usd", "artifacts"),
          timeout_sec: cfg.dig("timeout_sec", "artifacts") || Hive::Config::DEFAULTS.dig("timeout_sec", "artifacts"),
          log_label: "artifacts",
          profile: profile,
          status_mode: :state_file_marker
        }
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("7-artifacts", task),
            allowed_tools: "Read,Write,Edit,Bash,LS,Glob,Grep"
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
      end

      def render_prompt(task)
        Hive::Stages::Base.render(
          "artifacts_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: task.worktree_path,
            artifact_file: task.state_file,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def action_for(marker_name)
        case marker_name
        when :complete then "artifacts_collected"
        when :error then "error"
        else marker_name.to_s
        end
      end
    end
  end
end
