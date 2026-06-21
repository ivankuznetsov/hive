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

        # Read the descriptor's instruction defensively: it can be renamed,
        # deleted, or chmod'd between descriptor parse and this run (a normal
        # authoring edit). Mirror the sibling `prior_artifacts` SystemCallError
        # rescue, but because the stage's OWN instruction going missing is fatal
        # (not a degradable sibling artifact), stamp an attributed :error marker
        # and stop — instead of dying with a raw Errno::ENOENT and no marker,
        # which would leave the row silently re-classifying as ready_to_run.
        begin
          instruction_body = stage.instruction && File.read(stage.instruction)
        rescue SystemCallError => e
          return instruction_error_result(output_path, e)
        end
        prompt = render_prompt(task, cfg, stage, profile: profile, instruction_body: instruction_body)
        permission_kwargs = stage.permissions.nil? ? {} : { explicit_permission_spec: stage.permissions }
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, task.stage_name, task, profile, **permission_kwargs
        )

        result = Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", task.stage_name) || stage.budget_usd,
          timeout_sec: cfg.dig("timeout_sec", task.stage_name) || stage.timeout_sec || DEFAULT_TIMEOUT_SEC,
          log_label: task.stage_name,
          profile: profile,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          # Honor the descriptor's declared status_mode; fall back to the
          # marker-file convention only when the stage leaves it unset.
          status_mode: stage.status_mode || :state_file_marker,
          cfg: cfg
        )

        marker = Hive::Markers.current(output_path)
        # `spawn_agent` returns a `{status: :error}` envelope WITHOUT writing
        # a marker on a preflight/version failure (base.rb) — unlike the
        # coding claude path, which routes through
        # `spawn_claude_with_tmux_marker!` and stamps an attributed marker.
        # The generic runner uses bare `spawn_agent` for every profile, so we
        # must consume that envelope here: otherwise the reread yields the
        # marker from a PRIOR run (`:none` on a first run, but a stale
        # `:waiting`/`:complete` when the operator edits and re-runs an
        # already-markered stage), `hive run` exits 0 reporting that status,
        # and the preflight failure is unobservable (NO-SILENT-CAPS). The
        # `{status: :error}` envelope means the spawn wrote no marker THIS run,
        # so overwriting any stale marker with the attributed `:error` is
        # correct — there is no agent-written marker to clobber.
        if result.is_a?(Hash) && result[:status] == :error
          Hive::Markers.set(
            output_path, :error,
            reason: "agent_preflight_failed",
            message: result[:error_message].to_s[0, 200]
          )
          marker = Hive::Markers.current(output_path)
        end
        { commit: action_for(marker.name), status: marker.name }
      end

      def render_prompt(task, _cfg, stage, profile:, instruction_body:)
        skill_invocation = stage.skill && profile.format_skill_invocation(stage.skill)
        Hive::Stages::Base.render(
          "agent_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            stage_name: task.stage_name,
            output_file: stage.state_file,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            prior_context: prior_artifacts(task, stage.state_file),
            skill_invocation: skill_invocation,
            instruction_body: instruction_body
          )
        )
      end

      # Stamp an attributed :error marker for an unreadable instruction file and
      # return the same result shape as a normal run, so the row classifies as
      # :error rather than dying with an uncaught SystemCallError. The
      # instruction read happens BEFORE any spawn, so no agent wrote a marker
      # this run — overwrite any marker present (`:none` on a first run, but a
      # stale `:waiting`/`:complete` when the operator re-runs an already-markered
      # stage whose instruction has since become unreadable), or the failure is
      # unobservable and the row silently re-classifies as ready_to_run.
      def instruction_error_result(output_path, error)
        Hive::Markers.set(
          output_path, :error,
          reason: "instruction_unreadable",
          message: "#{error.class}: #{error.message}"[0, 200]
        )
        marker = Hive::Markers.current(output_path)
        { commit: action_for(marker.name), status: marker.name }
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
        # A markerless (:none) run has nothing to commit; return nil so
        # commit_after's `return unless result[:commit]` guard skips the commit
        # outright, instead of relying on hive_commit's empty-diff no-op to
        # swallow a bogus "none" action.
        when :none then nil
        else marker_name.to_s
        end
      end
    end
  end
end
