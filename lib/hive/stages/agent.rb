require "hive/agent_limit"
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
      DEFAULT_TIMEOUT_SEC = Hive::Stages::Base::DEFAULT_GENERIC_STAGE_TIMEOUT_SEC

      def run!(task, cfg)
        cfg ||= {}
        stage = task.workflow.stage_named(task.stage_name)
        stage or raise Hive::StageError, "no agent stage #{task.stage_name}"
        output_path = File.join(task.folder, stage.state_file)
        profile = Hive::Stages::Base.stage_profile(cfg, task.stage_name, explicit_agent: stage.agent)

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
        resource_limits = Hive::Stages::Base.stage_resource_limits(cfg, stage)

        result = Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: task.folder,
          **resource_limits,
          log_label: task.stage_name,
          profile: profile,
          model: stage.model,
          effort: stage.effort,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          # Honor the descriptor's declared status_mode; fall back to the
          # marker-file convention only when the stage leaves it unset.
          status_mode: stage.status_mode || :state_file_marker,
          cfg: cfg
        )

        marker = Hive::Markers.current(output_path)
        # `spawn_agent` returns `{status: :error}` for both preflight failures
        # and provider quota walls. In state-file mode Hive::Agent may already
        # have written the retryable limit marker; other status modes only
        # carry the wall in the result envelope. Preserve/classify those quota
        # failures before the generic preflight fallback so the daemon can
        # honor `retry_after` instead of parking the task permanently.
        if result.is_a?(Hash) && result[:status] == :error
          if Hive::AgentLimit.held?(marker.name, marker.attrs)
            # The agent already wrote the authoritative quota marker.
          elsif limit_error_envelope?(result)
            Hive::Markers.set(
              output_path, :error,
              reason: "limits_reached",
              provider: profile.name,
              message: result[:error_message].to_s[0, 200],
              retry_after: Hive::AgentLimit.retry_after
            )
          else
            # A preflight/version failure writes no marker. Overwrite any
            # stale marker from a prior run so the failure stays observable.
            Hive::Markers.set(
              output_path, :error,
              reason: "agent_preflight_failed",
              message: result[:error_message].to_s[0, 200]
            )
          end
          marker = Hive::Markers.current(output_path)
        end
        commit = Hive::AgentLimit.held?(marker.name, marker.attrs) ? "limits_reached" : action_for(marker.name)
        { commit: commit, status: marker.name }
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

      def limit_error_envelope?(result)
        Hive::AgentLimit.limit_reached?(result[:limit_text].to_s) ||
          Hive::AgentLimit.from_limit?(result[:error_message].to_s) ||
          Hive::AgentLimit.limit_reached?(result[:error_message].to_s)
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
