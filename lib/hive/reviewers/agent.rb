require "hive/reviewers/base"
require "hive/agent_profiles"
require "hive/stages/base"

module Hive
  module Reviewers
    # Agent-based reviewer: spawns an LLM CLI (claude, codex, pi) with a
    # rendered prompt that invokes a CE skill on the worktree's diff.
    # The agent writes its findings to `reviews/<output_basename>-<pass>.md`;
    # success is detected via the profile's :output_file_exists mode (file
    # exists + non-empty + exit 0).
    class Agent < Base
      def initialize(spec, ctx, cfg: nil)
        super(spec, ctx)
        @cfg = cfg
      end

      def run!(deadline: nil)
        ensure_reviews_dir!

        profile = Hive::AgentProfiles.lookup(spec.fetch("agent"), cfg: @cfg)
        skill = spec.fetch("skill")
        prompt = render_prompt(profile, skill)
        max_attempts = max_attempts_from_spec
        configured_timeout = spec["timeout_sec"] || 600

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
        # timeout_sec + backoff (e.g. 3 × 600 + 7 = 1807s) and exhaust
        # the outer review wall_clock budget before the
        # between-reviewer check in run_reviewers fires.
        attempts = 0
        result = nil
        loop do
          attempts += 1
          # ce-review P1 #3 (round 2): clear stale output_path before
          # every attempt so a partial file from a prior crashed
          # attempt cannot satisfy the next attempt's
          # :output_file_exists check.
          File.delete(output_path) if File.exist?(output_path)

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

          result = Hive::Stages::Base.spawn_agent(
            synthetic_task,
            prompt: prompt,
            add_dirs: [ ctx.task_folder ],
            cwd: ctx.worktree_path,
            max_budget_usd: spec["budget_usd"] || 50,
            timeout_sec: spawn_timeout || configured_timeout,
            log_label: build_log_label(attempts),
            profile: profile,
            expected_output: output_path,
            # Reviewer spawns own a per-pass output file, not the task
            # marker — the orchestrator's REVIEW_WORKING marker must
            # persist across each reviewer's spawn.
            status_mode: :output_file_exists
          )
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
        if result[:status] != :ok && File.exist?(output_path)
          File.delete(output_path)
        end

        build_result(result, attempts, max_attempts)
      end

      private

      def max_attempts_from_spec
        value = spec["max_attempts"]
        return Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        # Defensive fallback: if a config path bypasses
        # Hive::Config.validate_reviewers! and passes a non-integer
        # value through, default rather than crash mid-spawn. The
        # adapter is the wrong place to surface a config-validation
        # error.
        Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS
      end

      def build_log_label(attempt)
        base = "review-#{name}-pass#{format('%02d', ctx.pass)}"
        attempt > 1 ? "#{base}-retry#{attempt - 1}" : base
      end

      def backoff_seconds_for(failed_attempt)
        [ 2**(failed_attempt - 1), Hive::Reviewers::REVIEWER_BACKOFF_CAP_SEC ].min
      end

      # ce-review round-3 P1 #3 helpers. `deadline` is a monotonic
      # timestamp; `nil` means "no caller-imposed deadline" and the
      # adapter behaves identically to pre-deadline code.
      def deadline_remaining(deadline)
        deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def effective_timeout(configured_timeout, deadline)
        return configured_timeout unless deadline

        remaining = deadline_remaining(deadline)
        return remaining.floor if remaining <= 0

        [ configured_timeout, remaining.floor ].min
      end

      # Indirected so tests can stub the wait without burning wall time.
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
          # Suppress the "after N attempt(s)" suffix when max_attempts
          # is 1 so single-attempt configurations get the original
          # error_message shape (consumed by callers that hand-write
          # the orchestrator-owned errors-NN.md line in U2).
          msg = max_attempts > 1 ? "#{base_msg} after #{attempts} attempt(s)" : base_msg
          Result.new(
            name: name,
            output_path: output_path,
            status: :error,
            error_message: msg
          )
        end
      end

      def render_prompt(profile, skill)
        template_path = Hive::Stages::Base.resolve_template_path(
          spec.fetch("prompt_template"),
          hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
        )
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
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      # spawn_agent expects a task-shaped object with folder, state_file,
      # log_dir, and stage_name. Use the shared
      # Hive::Reviewers.synthetic_task_for helper so every 5-review
      # sub-spawn agrees on the facade layout (M-04).
      def synthetic_task
        Hive::Reviewers.synthetic_task_for(ctx)
      end
    end
  end
end
