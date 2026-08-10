require "hive/reviewers/base"
require "hive/reviewers/plan_context"
require "hive/agent_profiles"
require "hive/stages/base"

module Hive
  module Reviewers
    # Agent-based reviewer: spawns an LLM CLI (claude, codex, pi, grok) with a
    # rendered prompt that invokes a CE skill on the worktree's diff.
    # The agent writes its findings to `reviews/<output_basename>-<pass>.md`;
    # success is detected via the profile's :output_file_exists mode (file
    # exists + non-empty + exit 0).
    class Agent < Base
      # Per-reviewer wall-clock cap. A deep code review legitimately runs
      # 1-2h, so default to 2h; the previous 1h cap killed thorough
      # reviewers mid-run. Override per reviewer via `spec["timeout_sec"]`.
      DEFAULT_TIMEOUT_SEC = 7200

      def initialize(spec, ctx, cfg: nil)
        super(spec, ctx)
        @cfg = cfg
      end

      def run!(deadline: nil)
        run_with_spawn(deadline: deadline) do |profile, prompt, configured_timeout, spawn_timeout, attempts|
          scope = Hive::Stages::Base.stage_permission_scope(
            @cfg || {}, "review.reviewers", synthetic_task, profile,
            base_add_dirs: [ ctx.task_folder ],
            **Hive::Stages::Base.explicit_permission_kwargs(spec)
          )
          Hive::Stages::Base.spawn_agent(
            synthetic_task,
            prompt: prompt,
            add_dirs: scope.fetch(:add_dirs),
            cwd: ctx.worktree_path,
            max_budget_usd: spec["budget_usd"] || 50,
            timeout_sec: spawn_timeout || configured_timeout,
            log_label: build_log_label(attempts),
            profile: profile,
            expected_output: output_path,
            cfg: @cfg,
            routing_arguments: Hive::Stages::Base.model_routing_arguments(
              @cfg || {}, "review_reviewers", profile,
              current: Hive::Stages::Base.model_routing_current(spec)
            ),
            **Hive::Stages::Base.tool_scope_kwargs(scope),
            # Reviewer spawns own a per-pass output file, not the task
            # marker — the orchestrator's REVIEW_WORKING marker must
            # persist across each reviewer's spawn.
            status_mode: :output_file_exists
          )
        end
      end

      def run_in_session!(handle:, deadline: nil)
        run_with_spawn(deadline: deadline) do |profile, prompt, configured_timeout, spawn_timeout, attempts|
          unless profile.name == :claude
            raise Hive::AgentError, "shared Claude reviewer session cannot run #{profile.name.inspect}"
          end

          handle.send_and_wait!(
            prompt: prompt,
            expected_output: output_path,
            timeout_sec: spawn_timeout || configured_timeout,
            status_mode: :output_file_exists,
            log_label: build_log_label(attempts),
            deadline: deadline
          )
        end
      end

      private

      def run_with_spawn(deadline:)
        ensure_reviews_dir!

        profile = Hive::AgentProfiles.lookup(spec.fetch("agent"), cfg: @cfg)
        skill = spec.fetch("skill")
        prompt = render_prompt(profile, skill)
        max_attempts = max_attempts_from_spec
        configured_timeout = spec["timeout_sec"] || DEFAULT_TIMEOUT_SEC

        # Adapter-local retry loop. A reviewer that times out or fails
        # transiently is retried up to max_attempts times before the
        # final :error envelope is returned. This keeps infra flakes
        # (CLI timeouts, momentary API blips) from polluting the
        # orchestrator's escalations file with `reviewer "X" failed:`
        # lines the user has to triage as if they were real findings.
        #
        # ce-review round-3 P1 #3 — the optional `deadline:` is a
        # monotonic timestamp (Process.clock_gettime(:MONOTONIC)) beyond
        # which the adapter must not start a new spawn. Each spawn's
        # effective timeout is capped at `deadline - now`; backoff
        # sleeps are also clamped to that remaining budget. Without
        # this, a single reviewer could consume max_attempts ×
        # timeout_sec + backoff (defaults: 2 × 7200 + 1 = 14401s; with
        # max_attempts: 3 override: 3 × 7200 + 3 = 21603s) and exhaust
        # the outer review wall_clock budget (14400s default) before
        # the between-reviewer check in run_reviewers fires.
        attempts = 0
        result = nil
        loop do
          attempts += 1
          # ce-review P1 #3 (round 2): clear stale output_path before
          # every attempt so a partial file from a prior crashed
          # attempt cannot satisfy the next attempt's
          # :output_file_exists check.
          clear_partial_output!(:pre_attempt)

          spawn_timeout = effective_timeout(configured_timeout, deadline)
          if spawn_timeout && spawn_timeout <= 0
            # Deadline reached before this attempt starts — surface a
            # deterministic error envelope rather than spawning with
            # a non-positive timeout.
            result = {
              status: :error,
              error_message: "deadline reached before attempt #{attempts}"
            }
            break
          end

          result = yield(profile, prompt, configured_timeout, spawn_timeout, attempts)
          break if result[:status] == :ok
          break if attempts >= max_attempts

          sleep_seconds = backoff_seconds_for(attempts)
          if deadline
            remaining = deadline_remaining(deadline)
            break if remaining <= 0

            sleep_seconds = [ sleep_seconds, remaining ].min
          end
          backoff(sleep_seconds)
        end

        # ce-review P1 #3 (final-failure cleanup): the last attempt may
        # have left a partial output_path file behind. Triage's
        # discover_reviewer_files would otherwise find it and treat it
        # as real reviewer output. Final failures must surface only
        # through reviews/errors-NN.md (written by the orchestrator's
        # run_reviewers in lib/hive/stages/review.rb), not via a stale
        # output_path file.
        clear_partial_output!(:final_failure) if result[:status] != :ok

        build_result(result, attempts, max_attempts)
      end

      # pr-review-toolkit round-5 M2: TOCTOU-safe wrapper for the two
      # `File.delete(output_path)` sites in the retry loop. Distinguishes
      # ENOENT (file may not exist on first attempt — normal) from
      # other SystemCallError (perms / read-only mount — diagnostic).
      # The `stage` label lets the resulting `errors-NN.md` line name
      # which delete failed (pre-attempt clear vs. final-failure
      # cleanup).
      def clear_partial_output!(stage)
        File.delete(output_path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Hive::Error,
              "reviewer #{name.inspect}: failed to clear partial output_path " \
              "(#{stage}) #{output_path}: #{e.class}: #{e.message}"
      end

      def build_log_label(attempt)
        base = "review-#{name}-pass#{format('%02d', ctx.pass)}"
        attempt > 1 ? "#{base}-retry#{attempt - 1}" : base
      end

      def backoff_seconds_for(failed_attempt)
        Hive::Reviewers.backoff_seconds_for(failed_attempt)
      end

      def backoff(seconds)
        sleep(seconds)
      end

      def build_result(spawn_result, attempts, max_attempts)
        if spawn_result[:status] == :ok
          Result.new(
            name: name,
            output_path: output_path,
            status: :ok,
            error_message: nil
          )
        else
          base_msg = spawn_result[:error_message] ||
                     "agent exited with status=#{spawn_result[:status]}"
          # With max_attempts=1 retry is disabled by config; an
          # "after 1 attempt(s)" suffix would be redundant and slightly
          # misleading (it implies a retry policy that's been turned
          # off). Keep the bare error message in that case.
          msg = max_attempts > 1 ? "#{base_msg} after #{attempts} attempt(s)" : base_msg
          Result.new(
            name: name,
            output_path: output_path,
            status: :error,
            error_message: msg,
            limit_text: spawn_result[:limit_text]
          )
        end
      end

      def render_prompt(profile, skill)
        template_path = Hive::Stages::Base.resolve_template_path(
          spec.fetch("prompt_template"),
          hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
        )
        # Generate one nonce per spawn (ADR-019) and reuse it for
        # both `user_supplied_tag` (the template's own bindings) and
        # the plan_context_section's inner wrapper, so the reviewer
        # sees a single consistent nonce across the whole prompt.
        # Drift would let an attacker who controls one content source
        # forge a wrapper that looks like another's.
        tag = Hive::Stages::Base.user_supplied_tag
        Hive::Stages::Base.render_resolved_path(
          template_path,
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(ctx.worktree_path),
            worktree_path: ctx.worktree_path,
            task_folder: ctx.task_folder,
            default_branch: ctx.default_branch,
            pass: ctx.pass,
            output_path: output_path,
            skill_invocation: profile.format_skill_invocation(skill),
            user_supplied_tag: tag,
            plan_context_section: Hive::Reviewers::PlanContext.render(ctx.task_folder, tag)
          )
        )
      end

      # spawn_agent expects a task-shaped object with folder, state_file,
      # log_dir, and stage_name. Use the shared
      # Hive::Reviewers.synthetic_task_for helper so every 6-review
      # sub-spawn agrees on the facade layout (M-04).
      def synthetic_task
        Hive::Reviewers.synthetic_task_for(ctx)
      end
    end
  end
end
