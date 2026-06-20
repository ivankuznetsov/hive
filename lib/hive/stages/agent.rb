require "hive/markers"
require "hive/stages/base"
require "hive/workflows/registry"

module Hive
  module Stages
    module Agent
      module_function

      def run!(task, cfg)
        cfg ||= {}
        stage = task.workflow.stage_named(task.stage_name)
        stage or raise Hive::StageError, "no agent stage #{task.stage_name}"
        output_path = File.join(task.folder, stage.state_file)
        profile = Hive::Stages::Base.stage_profile(cfg, task.stage_name)
        prompt = render_prompt(task, cfg, stage, profile: profile)

        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", task.stage_name) || stage.budget_usd,
          timeout_sec: cfg.dig("timeout_sec", task.stage_name) || stage.timeout_sec,
          log_label: task.stage_name,
          profile: profile,
          status_mode: :state_file_marker,
          cfg: cfg
        )

        marker = Hive::Markers.current(output_path)
        { commit: action_for(marker.name), status: marker.name }
      end

      def render_prompt(task, _cfg, stage, profile:)
        skill_invocation = stage.skill && profile.format_skill_invocation(stage.skill)
        Hive::Stages::Base.render(
          "agent_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            stage_name: task.stage_name,
            output_file: stage.state_file,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            prior_context: prior_artifacts(task, stage.state_file),
            skill_invocation: skill_invocation
          )
        )
      end

      def prior_artifacts(task, output_file)
        # Guardrail against flooding the prompt with historical artifacts: a hard 8000-char cap
        # on the whole joined string (not per-file or token-based), applied by the [0, 8000] slice.
        Dir.glob(File.join(task.folder, "*.md")).sort.filter_map do |path|
          next if File.basename(path) == output_file

          "## #{File.basename(path)}\n#{File.read(path)}"
        end.join("\n\n")[0, 8000]
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
