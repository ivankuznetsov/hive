require "securerandom"
require "hive/stages/base"
require "hive/claude_launcher"
require "hive/plan_review/marker_sync"
require "hive/plan_review/orchestrator"
require "hive/plan_review/projection"
require "hive/plan_review/transition_guard"
require "hive/plan_review/disposable_worktree"
require "hive/plan_review/planner_identity"
require "hive/plan_dependency_adoption"
require "hive/plan_dependency_correction"
require "hive/plan_frontmatter"
require "hive/dependencies"
require "hive/dependency_snapshot"
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

      def run!(task, cfg, explicit_plan_repair: false)
        observation = Hive::DependencySnapshot.observe_for_admission!(
          task, missing_message: "plan task is missing before execution"
        )

        if cleared_plan_ready?(task, cfg)
          validation = Hive::PlanDependencyAdoption.validate(task)
          if validation.ok? && !validation.adoptable?
            return { commit: action_for(:complete), status: :complete, plan_review: nil }
          end

          unless explicit_plan_repair && validation.covered_defect?
            Hive::PlanDependencyCorrection.record_cleared_plan_diagnostic!(
              task.folder,
              observation: observation,
              plan_digest: validation.plan_digest,
              diagnostic: validation
            )
            warn "[hive] plan: cleared plan #{task.slug} failed dependency validation " \
                 "(#{validation.reason_code || 'plan_dependency_missing'}: #{validation.offending_ref}); " \
                 "replan explicitly with `#{Hive::PlanDependencyCorrection.repair_command(task)}`"
            return {
              commit: nil,
              status: :error,
              plan_review: nil,
              dependency_diagnostic: validation.to_h
            }
          end

          return with_source_checkout(task) do |source|
            run_with_source!(
              task, cfg, source,
              observation: observation,
              explicit_plan_repair: true,
              pre_existing_validation: validation
            )
          end
        end

        with_source_checkout(task) do |source|
          run_with_source!(
            task, cfg, source,
            observation: observation,
            explicit_plan_repair: explicit_plan_repair
          )
        end
      ensure
        observation&.close
      end

      # A complete plan whose review cleared and is still current is ready to
      # develop. Re-running the planner here edited plan.md, staled the cleared
      # review and opened a fresh review cycle, discarding the convergence the
      # operator had just reached. Leave it untouched; `hive develop` moves it on.
      def cleared_plan_ready?(task, cfg)
        return false unless Hive::Markers.current(task.state_file).name == :complete

        projection = Hive::PlanReview::Projection.load(task_folder: task.folder)
        return false unless projection.record.execution_allowed?

        Hive::PlanReview::TransitionGuard.freshness(
          task: task, projection: projection, config: cfg
        ).fetch("status") == "current"
      rescue Hive::PlanReview::InvalidRecord, Hive::PlanReview::InvalidPlan, SystemCallError, IOError
        false
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

      def run_with_source!(task, cfg, source_checkout, observation:,
                           explicit_plan_repair: false, pre_existing_validation: nil)
        if explicit_plan_repair
          existing_defect = pre_existing_validation || existing_covered_defect(task)
          invocation_id = Hive::PlanDependencyCorrection.start_explicit_invocation!(
            task.folder,
            observation: observation,
            existing_diagnostic: existing_defect
          )
          initial_diagnostic_text = existing_defect ?
            Hive::PlanDependencyCorrection.format_prompt_diagnostic(existing_defect) : ""
        else
          if Hive::PlanDependencyCorrection.initial_exhausted?(task.folder)
            ensure_exhausted_marker!(task)
            return { commit: action_for(:error), status: :error, plan_review: nil }
          end
          invocation_id = Hive::Attempts::Context.current&.attempt_id ||
            "plan-#{SecureRandom.hex(12)}"
          initial_diagnostic_text = ""
        end

        brainstorm_path = File.join(task.folder, "brainstorm.md")
        brainstorm_text = File.exist?(brainstorm_path) ? File.read(brainstorm_path) : ""
        profile = Hive::Stages::Base.stage_profile(cfg, "plan")
        skill = Hive::Config.stage_skill(cfg, "plan")
        prompt = render_plan_prompt(
          task: task,
          brainstorm_text: brainstorm_text,
          source_checkout: source_checkout,
          profile: profile,
          skill: skill,
          dependency_diagnostic_text: initial_diagnostic_text
        )
        # See brainstorm.rb: add-dir narrowed to the task folder so a
        # prompt-injected brainstorm.md cannot reach the project source.
        ensure_durable_checkpoint!(task)
        result = spawn_plan_agent(task, cfg, prompt, profile, source_checkout: source_checkout)
        marker = Hive::Markers.current(task.state_file)

        if %i[waiting complete].include?(marker.name)
          validation = Hive::PlanDependencyAdoption.validate(task)
          if validation.covered_defect?
            reserved = Hive::PlanDependencyCorrection.reserve_initial_correction!(
              task.folder,
              observation: observation,
              invocation_id: invocation_id,
              input_digest: validation.plan_digest,
              diagnostic: validation
            )
            unless reserved
              exhaust_initial_plan_dependency!(
                task, observation: observation, invocation_id: invocation_id, validation: validation
              )
              return { commit: action_for(:error), status: :error, plan_review: nil }
            end

            correction_prompt = render_plan_prompt(
              task: task,
              brainstorm_text: brainstorm_text,
              source_checkout: source_checkout,
              profile: profile,
              skill: skill,
              dependency_diagnostic_text: Hive::PlanDependencyCorrection.format_prompt_diagnostic(validation)
            )
            result = spawn_plan_agent(task, cfg, correction_prompt, profile, source_checkout: source_checkout)
            marker = Hive::Markers.current(task.state_file)
            unless %i[waiting complete].include?(marker.name)
              return { commit: action_for(marker.name), status: marker.name, plan_review: nil }
            end

            validation = Hive::PlanDependencyAdoption.validate(task)
            if validation.covered_defect?
              exhaust_initial_plan_dependency!(
                task, observation: observation, invocation_id: invocation_id, validation: validation
              )
              return { commit: action_for(:error), status: :error, plan_review: nil }
            end
          end

          if validation.noncovered_error?
            warn "[hive] plan: deferring dependency adoption and review for #{task.slug} " \
                 "(#{validation.reason_code}: #{validation.offending_ref}; #{validation.safe_correction})"
            return { commit: action_for(marker.name), status: marker.name, plan_review: nil }
          end

          Hive::PlanDependencyCorrection.clear_initial_resolved!(
            task.folder, observation: observation, invocation_id: invocation_id
          )
          unless adopt_plan_dependency_with_status!(task, marker, observation: observation, validation: validation)
            return { commit: action_for(marker.name), status: marker.name, plan_review: nil }
          end
        end

        review = start_plan_review(
          task, cfg, profile, result, marker, observation: observation
        )
        Hive::PlanReview::MarkerSync.hold_until_cleared!(task:, projection: review)
        marker = Hive::Markers.current(task.state_file)
        {
          commit: action_for(marker.name), status: marker.name,
          plan_review: review&.summary
        }
      end

      def render_plan_prompt(task:, brainstorm_text:, source_checkout:, profile:, skill:,
                             dependency_diagnostic_text: "")
        Hive::Stages::Base.render(
          "plan_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            brainstorm_text: brainstorm_text,
            carried_decisions_text: carried_decisions_text(task),
            dependency_diagnostic_text: dependency_diagnostic_text.to_s,
            source_checkout: source_checkout,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            skill_invocation: Hive::Stages::Base.format_verified_skill_invocation(
              profile, skill, project_root: task.project_root
            )
          )
        )
      end

      def existing_covered_defect(task)
        return nil unless File.file?(task.state_file)

        validation = Hive::PlanDependencyAdoption.validate(task)
        validation.covered_defect? ? validation : nil
      rescue StandardError
        nil
      end

      def exhaust_initial_plan_dependency!(task, observation:, invocation_id:, validation:)
        Hive::PlanDependencyCorrection.mark_initial_exhausted!(
          task.folder,
          observation: observation,
          invocation_id: invocation_id,
          input_digest: validation.plan_digest,
          diagnostic: validation
        )
        Hive::Markers.set(
          task.state_file,
          :error,
          reason: Hive::PlanDependencyCorrection::EXHAUSTED_REASON,
          dependency_reason: validation.reason_code.to_s,
          offending_ref: validation.offending_ref.to_s,
          message: Hive::PlanDependencyCorrection.exhausted_message(task: task, validation: validation)
        )
      end

      def ensure_exhausted_marker!(task)
        marker = Hive::Markers.current(task.state_file)
        return if marker.name == :error && Hive::PlanDependencyCorrection.marker_exhausted?(marker.attrs)

        state = Hive::PlanDependencyCorrection.read(task.folder)
        diagnostic = state.dig("initial", "diagnostic")
        attrs = {
          reason: Hive::PlanDependencyCorrection::EXHAUSTED_REASON,
          message: Hive::PlanDependencyCorrection.exhausted_message(task: task, validation: nil)
        }
        if diagnostic.is_a?(Hash)
          attrs[:dependency_reason] = diagnostic["reason_code"].to_s if diagnostic["reason_code"]
          attrs[:offending_ref] = diagnostic["offending_ref"].to_s if diagnostic["offending_ref"]
          if diagnostic["reason_code"] && diagnostic["offending_ref"]
            attrs[:message] = "plan dependency correction exhausted " \
                              "(#{diagnostic['reason_code']}: #{diagnostic['offending_ref']}; " \
                              "#{diagnostic['safe_correction']}); Hive will not retry automatically. " \
                              "Repair with `#{Hive::PlanDependencyCorrection.repair_command(task)}`."
          end
        end
        Hive::Markers.set(task.state_file, :error, attrs)
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

      # Adopt the plan's frontmatter `depends_on` into meta.yml after the
      # initial planner run, for a complete plan only. The rule (absence or a
      # strict superset is adopted; anything that would drop or replace an
      # existing meta dependency is left for `plan_dependency_mismatch`) lives
      # in Hive::PlanDependencyAdoption, which plan-review candidate promotion
      # reuses.
      def adopt_plan_dependency!(task, marker, observation:, validation: nil)
        adopt_plan_dependency_with_status!(
          task, marker, observation: observation, validation: validation
        )
        nil
      end

      def adopt_plan_dependency_with_status!(task, marker, observation:, validation: nil)
        return true unless marker.name == :complete

        outcome = Hive::PlanDependencyAdoption.adopt_validated!(
          task, observation: observation, validation: validation
        )
        if outcome.stale? && validation
          outcome = Hive::PlanDependencyAdoption.adopt_validated!(
            task, observation: observation
          )
        end
        if outcome.ok?
          true
        elsif outcome.stale?
          warn "[hive] plan: stale task; dependency adoption skipped for #{task.slug}"
          false
        elsif outcome.status == :failed && outcome.error
          warn "[hive] plan: dependency adoption failed for #{task.slug} " \
               "(#{outcome.error.class}: #{outcome.error.message.to_s.byteslice(0, 240)})"
          false
        else
          false
        end
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
          max_budget_usd: Hive::Stages::Base.stage_budget_usd(cfg, "plan", profile),
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
        if Hive::AgentSupport.supports?(profile, :Launch)
          Hive::Stages::Base.spawn_claude_with_failure_marker!(task, cfg, **kwargs)
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

      def start_plan_review(task, cfg, profile, result, marker, observation:)
        return nil unless %i[waiting complete].include?(marker.name)
        return nil unless task.respond_to?(:workflow) && task.respond_to?(:meta_yml_path)

        Hive::PlanReview::Orchestrator.run!(
          task:, cfg:, planner_identity: planner_identity(profile, cfg, result),
          task_observation: observation
        )
      end

      def planner_identity(profile, cfg, result)
        Hive::PlanReview::PlannerIdentity.capture(
          profile:, cfg:,
          observed_model: result&.fetch(:model) { result.dig(:usage, :model) }
        )
      end
    end
  end
end
