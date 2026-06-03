require "fileutils"
require "hive/agent_profiles"
require "hive/babysitter/context_builder"
require "hive/babysitter/dry_run_env"
require "hive/babysitter/events"
require "hive/babysitter/gh_ops"
require "hive/babysitter/worktree"
require "hive/reviewers/synthetic_task"
require "hive/stages/base"

module Hive
  module Babysitter
    class PrFixer
      GIVE_UP_TAIL_BYTES = 4096

      def self.run(...)
        new(...).run
      end

      def initialize(pr, project, cfg, dry_run:, logger:, inflight:)
        @pr = pr
        @project = project
        @cfg = cfg
        @dry_run = dry_run
        @logger = logger
        @inflight = inflight
      end

      def run
        key = nil
        return :noop if @inflight.include?(inflight_key)

        key = inflight_key
        @inflight.add(key)
        started = Time.now

        if fork_pr?
          skip_fork_pr(started)
          return :fork_pr
        end

        # The early-green precheck runs `pr_status_rollup` against the project
        # root, not the worktree, because no PR worktree exists yet (materialize
        # happens below). gh resolves the same repo from either cwd's git
        # config, and the result is threaded into ContextBuilder so the second
        # call reuses this rollup rather than re-fetching.
        status = Hive::Gh.pr_status_rollup(@project.fetch("path"), number, cfg: @cfg)
        if already_green?(status)
          Hive::Babysitter::Events.emit(
            project: @project,
            pr: number,
            action: "noop",
            outcome: "already-green",
            duration_ms: duration_ms(started)
          )
          return :already_green
        end

        worktree = Hive::Babysitter::Worktree.materialize(@project, @pr)
        context = Hive::Babysitter::ContextBuilder.build(
          worktree_path: worktree.path,
          pr: @pr,
          cfg: @cfg,
          status_rollup: status
        )
        result = spawn_agent(worktree.path, context)
        outcome = outcome_for(result, worktree.path)
        emit_agent_event(outcome, started)
        return outcome if %i[success dry_run].include?(outcome)

        give_up(worktree.path, result, outcome, started)
        outcome
      ensure
        @inflight.delete(key) if key
      end

      private

      def number
        @pr.fetch("number")
      end

      def inflight_key
        [ @project.fetch("name"), number.to_i ]
      end

      # Fork (cross-repository) PRs cannot be repaired here: the agent's
      # rebase/force-push targets `origin`, which cannot update a
      # fork-owned head branch. Skip them gracefully — label
      # needs-human and emit a skipped event — rather than pushing to the
      # wrong target.
      def fork_pr?
        @pr["isCrossRepository"] == true
      end

      def skip_fork_pr(started)
        Hive::Babysitter::GhOps.add_label(
          @project.fetch("path"),
          number,
          Hive::Babysitter::GhOps::GIVE_UP_LABEL,
          cfg: @cfg,
          dry_run: @dry_run
        )
        Hive::Babysitter::Events.emit(
          project: @project,
          pr: number,
          action: "skipped",
          outcome: "fork_pr",
          duration_ms: duration_ms(started)
        )
      end

      def already_green?(status)
        status["mergeable"].to_s == "MERGEABLE" && checks_green_or_queued?(status["statusCheckRollup"])
      end

      def checks_green_or_queued?(checks)
        Array(checks).all? do |entry|
          next true unless entry.is_a?(Hash)

          conclusion = entry["conclusion"].to_s.upcase
          state = entry["state"].to_s.upcase
          status = entry["status"].to_s.upcase

          # Fail a hard-failed check out first, even when a retry is queued
          # (conclusion=FAILURE + status=QUEUED). Without this, the
          # "still progressing" branch below would read a re-queued failing
          # check as green and the repair agent would never run.
          next false if %w[FAILURE TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE].include?(conclusion)
          next false if state == "FAILURE"

          %w[SUCCESS NEUTRAL SKIPPED].include?(conclusion) ||
            %w[SUCCESS].include?(state) ||
            %w[QUEUED PENDING IN_PROGRESS].include?(status) ||
            %w[PENDING EXPECTED].include?(state)
        end
      end

      def spawn_agent(worktree_path, context)
        task = babysitter_task(worktree_path)
        profile = Hive::AgentProfiles.lookup(@cfg.dig("execute", "agent") || "claude", cfg: @cfg)
        prompt = render_prompt(worktree_path, context)
        spawn = lambda do
          Hive::Stages::Base.spawn_agent(
            task,
            prompt: prompt,
            max_budget_usd: budget_usd,
            timeout_sec: timeout_sec,
            add_dirs: [ worktree_path ],
            cwd: worktree_path,
            log_label: "babysitter-pr-#{number}",
            profile: profile,
            status_mode: :exit_code_only
          )
        end
        @dry_run ? Hive::Babysitter::DryRunEnv.with_env(worktree_path, &spawn) : spawn.call
      end

      def babysitter_task(_worktree_path)
        folder = File.join(@project.fetch("hive_state_path"), "babysitter", "pr-#{number}")
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        File.write(state_file, "# Babysitter PR #{number}\n") unless File.exist?(state_file)
        Hive::Reviewers::SyntheticTask.new(
          folder: folder,
          state_file: state_file,
          log_dir: File.join(folder, "logs"),
          stage_name: "babysitter",
          project_root: @project.fetch("path")
        )
      end

      def render_prompt(worktree_path, context)
        bindings = Hive::Stages::Base::TemplateBindings.new(
          pr_number: number,
          pr_url: @pr["url"],
          head_ref: @pr.fetch("headRefName"),
          base_ref: @pr.fetch("baseRefName"),
          failing_jobs: context.failing_jobs,
          mergeable_state: context.mergeable_state,
          dry_run: @dry_run,
          worktree_path: worktree_path,
          user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
          budget_minutes: budget_minutes,
          budget_usd: budget_usd,
          diff_stat: context.diff_stat,
          base_sha: context.base_sha,
          merge_base: context.merge_base,
          ahead: context.ahead,
          behind: context.behind
        )
        Hive::Stages::Base.render("babysitter_pr_fix_prompt.md.erb", bindings)
      end

      def outcome_for(result, worktree_path = nil)
        return :timeout if result[:status] == :timeout || result[:timed_out]
        return :budget_exhausted if budget_exhausted?(result)
        if @dry_run && result[:status] == :ok
          return :dry_run if worktree_path && File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md"))

          return :failure
        end
        return :success if result[:status] == :ok

        :failure
      end

      def budget_exhausted?(result)
        status = result[:status]
        reason = result[:reason].to_s
        %i[budget_exceeded budget_exhausted].include?(status) ||
          reason == "budget_exceeded" ||
          reason == "budget_exhausted"
      end

      def emit_agent_event(outcome, started)
        event_outcome = case outcome
        when :success then "success"
        when :dry_run then "dry_run"
        when :timeout then "timeout"
        when :budget_exhausted then "budget_exhausted"
        else "failure"
        end
        Hive::Babysitter::Events.emit(
          project: @project,
          pr: number,
          action: outcome == :dry_run ? "dry_run" : "agent-fix",
          outcome: event_outcome,
          duration_ms: duration_ms(started)
        )
      end

      def give_up(worktree_path, result, outcome, started)
        label_result = Hive::Babysitter::GhOps.add_label(
          worktree_path,
          number,
          Hive::Babysitter::GhOps::GIVE_UP_LABEL,
          cfg: @cfg,
          dry_run: @dry_run
        )
        Hive::Babysitter::Events.emit(
          project: @project,
          pr: number,
          action: "label-apply",
          outcome: @dry_run ? "dry_run" : (label_result.success? ? "success" : "failure")
        )

        comment_result = Hive::Babysitter::GhOps.post_pr_comment(
          worktree_path,
          number,
          give_up_comment(result, outcome),
          cfg: @cfg,
          dry_run: @dry_run
        )
        Hive::Babysitter::Events.emit(
          project: @project,
          pr: number,
          action: "pr-comment",
          outcome: @dry_run ? "dry_run" : (comment_result.success? ? "success" : "failure")
        )

        give_up_outcome =
          if @dry_run
            # No real-world give-up happens in dry-run; tag it dry_run so an
            # audit grep of events.jsonl for genuine give-ups stays accurate.
            "dry_run"
          else
            case outcome
            when :timeout then "timeout"
            when :budget_exhausted then "budget_exhausted"
            else "failure"
            end
          end
        Hive::Babysitter::Events.emit(
          project: @project,
          pr: number,
          action: "give-up",
          outcome: give_up_outcome,
          duration_ms: duration_ms(started)
        )
      end

      def give_up_comment(result, outcome)
        tail = (result[:final_message] || result[:error_message] || "agent exited without a final message").to_s
        if tail.bytesize > GIVE_UP_TAIL_BYTES
          tail = tail.byteslice(-GIVE_UP_TAIL_BYTES, GIVE_UP_TAIL_BYTES).to_s
        end
        tail = tail.scrub
        <<~BODY
          hive-babysitter could not repair this PR automatically.

          Outcome: #{outcome}

          Agent tail:

          ```
          #{tail}
          ```
        BODY
      end

      def budget_minutes
        @cfg.dig("babysitter", "budget_minutes").to_i
      end

      def timeout_sec
        budget_minutes * 60
      end

      def budget_usd
        @cfg.dig("babysitter", "budget_usd").to_i
      end

      def duration_ms(started)
        ((Time.now - started) * 1000).to_i
      end
    end
  end
end
