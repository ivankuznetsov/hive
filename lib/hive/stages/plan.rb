require "hive/stages/base"
require "hive/claude_launcher"
require "hive/plan_review/marker_sync"
require "hive/plan_review/orchestrator"
require "hive/plan_review/disposable_worktree"
require "hive/plan_review/planner_identity"
require "hive/plan_frontmatter"
require "hive/dependencies"
require "hive/task_meta"

module Hive
  module Stages
    module Plan
      DURABLE_CHECKPOINT = <<~MARKDOWN.freeze
        # Plan checkpoint

        > Hive created this non-terminal checkpoint before starting the planner.
        > Replace the placeholders with the researched plan as work progresses.

        ## Overview

        _Planner checkpoint: pending._

        ## Requirements Trace

        _Planner checkpoint: pending._

        ## Scope Boundaries

        _Planner checkpoint: pending._

        ## Implementation Units

        _Planner checkpoint: pending._

        ## Risks

        _Planner checkpoint: pending._
      MARKDOWN

      module_function

      def run!(task, cfg)
        with_source_checkout(task) { |source| run_with_source!(task, cfg, source) }
      end

      # The planner must inspect the revision execution will start from.
      # Reading the project checkout directly can show an unrelated branch far
      # behind the default (plans then cite code that main has removed), so
      # give it a disposable detached checkout of the execution base. Planning
      # still proceeds without one if the checkout cannot be created.
      def with_source_checkout(task)
        Hive::PlanReview::DisposableWorktree.open(
          project_root: task.project_root, prefix: "hive-plan-source-"
        ) { |path| yield path }
      rescue Hive::PlanReview::InvalidRecord => e
        warn "[hive] plan: source checkout unavailable (#{e.message}); planning against the project checkout"
        yield nil
      end

      def run_with_source!(task, cfg, source_checkout)
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
            carried_decisions_text: carried_decisions_text(task),
            source_checkout: source_checkout,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            skill_invocation: Hive::Stages::Base.format_verified_skill_invocation(
              profile, skill, project_root: task.project_root
            )
          )
        )
        # See brainstorm.rb: add-dir narrowed to the task folder so a
        # prompt-injected brainstorm.md cannot reach the project source.
        ensure_durable_checkpoint!(task)
        result = spawn_plan_agent(task, cfg, prompt, profile, source_checkout: source_checkout)
        marker = Hive::Markers.current(task.state_file)
        adopt_plan_dependency!(task, marker)
        review = start_plan_review(task, cfg, profile, result, marker)
        Hive::PlanReview::MarkerSync.hold_until_cleared!(task:, projection: review)
        marker = Hive::Markers.current(task.state_file)
        {
          commit: action_for(marker.name), status: marker.name,
          plan_review: review&.summary
        }
      end

      CARRIED_DESCRIPTION_BYTES = 2_000
      CARRIED_ANSWER_BYTES = 4_000
      CARRIED_ACTIONS = %w[approve_finding answer_finding].freeze

      # A review that ends blocked (for example at its revision-round limit)
      # asks for a new linked plan. Its operator decisions may exist only in
      # candidate plans that were never promoted to plan.md, and the planner
      # prompt otherwise carries only brainstorm.md and plan.md, so those
      # decisions were silently dropped and the next review re-raised the same
      # questions. Hand every operator approval and answer from that review to
      # the planner as data to integrate.
      def carried_decisions_text(task)
        record = Hive::PlanReview::Projection.load(task_folder: task.folder).record
        return "" unless record.state == "blocked"

        findings = record["findings"].to_h { |finding| [ finding["fingerprint"], finding ] }
        decisions = record["decisions"].select { |decision| CARRIED_ACTIONS.include?(decision["action"]) }
        entries = decisions.filter_map do |decision|
          finding = findings[decision["target_fingerprint"]]
          next unless finding

          [ finding, decision ]
        end
        return "" if entries.empty?

        entries.sort_by { |finding, _| finding["display_order"].to_i }.map do |finding, decision|
          outcome = if decision["action"] == "answer_finding"
            answer = decision["value"].is_a?(Hash) ? decision["value"]["answer"] : decision["value"]
            "Operator answer (follow exactly): #{answer.to_s.byteslice(0, CARRIED_ANSWER_BYTES).scrub}"
          else
            "Operator decision: approved; apply the reviewer's recommendation."
          end
          <<~ENTRY
            - #{finding['title']} (#{finding['classification']}, #{finding['risk']} risk; #{finding['fingerprint']})
              Reviewer finding: #{finding['description'].to_s.byteslice(0, CARRIED_DESCRIPTION_BYTES).scrub}
              #{outcome}
          ENTRY
        end.join("\n")
      rescue Hive::PlanReview::Error, SystemCallError, IOError
        ""
      end

      # Seed before Agent.run! appends AGENT_WORKING. Provider errors then
      # replace only that trailing marker, so the next autonomous attempt sees
      # a structured artifact instead of another empty file. Existing plan or
      # feedback bytes always win; this helper is deliberately idempotent.
      def ensure_durable_checkpoint!(task)
        Hive::Markers.seed_body_if_empty(task.state_file, DURABLE_CHECKPOINT)
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
        return if reference == task.slug

        Hive::TaskMeta.rewrite(task.folder, depends_on: reference)
      rescue StandardError
        # Adoption is a convenience over an existing admission check. If it
        # fails we must not fail the plan stage: admission still catches the
        # mismatch and tells the operator exactly what to do.
        nil
      end

      def spawn_plan_agent(task, cfg, prompt, profile, source_checkout: nil)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "plan", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
        )
        kwargs = {
          prompt: prompt,
          add_dirs: (scope.fetch(:add_dirs) + [ source_checkout ].compact).uniq,
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
        if Hive::AgentSupport.supports?(profile, :Interactive)
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
        Hive::PlanReview::PlannerIdentity.capture(
          profile:, cfg:,
          observed_model: result&.dig(:usage, :model)
        )
      end
    end
  end
end
