require "hive/stages/base"
require "hive/claude_launcher"
require "hive/plan_review/orchestrator"
require "hive/plan_frontmatter"
require "hive/dependencies"
require "hive/task_meta"

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
            skill_invocation: Hive::Stages::Base.format_verified_skill_invocation(
              profile, skill, project_root: task.project_root
            )
          )
        )
        # See brainstorm.rb: add-dir narrowed to the task folder so a
        # prompt-injected brainstorm.md cannot reach the project source.
        result = spawn_plan_agent(task, cfg, prompt, profile)
        marker = Hive::Markers.current(task.state_file)
        adopt_plan_dependency!(task, marker)
        review = start_plan_review(task, cfg, profile, result, marker)
        {
          commit: action_for(marker.name), status: marker.name,
          plan_review: review&.summary
        }
      end

      # A plan that declares `depends_on` in its frontmatter is stating a real
      # scheduling constraint, but only meta.yml gates dispatch. Leaving the two
      # out of step parked the task on an admission error whose only remedy was
      # an operator copying one string between two files — toil that reviews
      # nothing, since nobody re-derives whether the dependency is right before
      # pasting it.
      #
      # So absence is adopted and conflict still blocks: when meta.yml has no
      # dependency we persist the plan's, and when it has a different one the
      # `plan_dependency_mismatch` gate still stops everything for a human. A
      # dependency adopted here is not trusted blindly either — admission still
      # resolves the target and still reports `dependency_cycle` with the
      # offending path, which is a far better error than a copy instruction.
      def adopt_plan_dependency!(task, marker)
        return unless marker.name == :complete

        plan = Hive::PlanFrontmatter.read(File.join(task.folder, "plan.md"))
        return unless plan.valid?

        declared = plan.depends_on
        return if declared.nil? || declared.to_s.strip.empty?
        return unless Hive::TaskMeta.read(task.folder)[:depends_on].nil?

        # PlanFrontmatter already parsed and validated this into a Reference;
        # a malformed one never reaches here as :ok.
        reference = declared.to_s
        return if reference.empty? || reference == task.slug

        Hive::TaskMeta.rewrite(task.folder, depends_on: reference)
      rescue StandardError
        # Adoption is a convenience over an existing admission check. If it
        # fails we must not fail the plan stage: admission still catches the
        # mismatch and tells the operator exactly what to do.
        nil
      end

      def spawn_plan_agent(task, cfg, prompt, profile)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
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
          **Hive::Stages::Base.model_launch_arguments(
            cfg, "plan", profile,
            current: Hive::Stages::Base.model_routing_current(cfg["plan"])
          ),
          **Hive::Stages::Base.tool_scope_kwargs(scope),
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

      def start_plan_review(task, cfg, profile, result, marker)
        return nil unless %i[waiting complete].include?(marker.name)
        return nil unless task.respond_to?(:workflow) && task.respond_to?(:meta_yml_path)

        Hive::PlanReview::Orchestrator.run!(
          task:, cfg:, planner_identity: planner_identity(profile, cfg, result)
        )
      end

      def planner_identity(profile, cfg, result)
        routing = Hive::ModelRouting.resolve(
          models: cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: "plan", provider: profile.name,
          current: Hive::Stages::Base.model_routing_current(cfg["plan"]),
          legacy: Hive::Stages::Base.model_routing_current(cfg["claude"])
        )
        model = result&.dig(:usage, :model) || routing.model || cfg.dig("plan", "model") || "unknown"
        effort = routing.effort || cfg.dig("plan", "effort") || cfg.dig("claude", "effort") || "unknown"
        {
          "provider" => profile.name.to_s,
          "model" => model.to_s,
          "family" => planner_family(profile.name),
          "effort" => effort.to_s,
          "route" => profile.launcher_identity.to_s
        }.freeze
      end

      def planner_family(name)
        {
          claude: "anthropic", codex: "openai", grok: "grok", pi: "pi"
        }.fetch(name.to_sym, "unknown")
      end
    end
  end
end
