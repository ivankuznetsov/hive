require "hive/markers"
require "hive/stages/base"
require "hive/workflows/registry"

module Hive
  module Stages
    module Agent
      module_function

      # Fallback timeout for a generic :agent stage whose descriptor omits
      # `timeout_sec` and whose cfg carries no per-stage override. Without it,
      # `Hive::Agent#run` would do `Time.now + nil` and crash at spawn — the
      # budget path is nil-guarded downstream, the timeout path is not.
      DEFAULT_TIMEOUT_SEC = 1800

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
          timeout_sec: cfg.dig("timeout_sec", task.stage_name) || stage.timeout_sec || DEFAULT_TIMEOUT_SEC,
          log_label: task.stage_name,
          profile: profile,
          # Honor the descriptor's declared status_mode; fall back to the
          # marker-file convention only when the stage leaves it unset.
          status_mode: stage.status_mode || :state_file_marker,
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

          begin
            "## #{File.basename(path)}\n#{File.read(path)}"
          rescue SystemCallError => e
            # TOCTOU: a sibling artifact can be deleted or become unreadable
            # between the glob and the read. Degrade that one file to a
            # placeholder so it can't abort the whole generic stage run.
            "## #{File.basename(path)}\n(unreadable: #{e.class})"
          end
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
