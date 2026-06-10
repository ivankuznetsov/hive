require "open3"
require "shellwords"
require "hive/reviewers/base"
require "hive/reviewers/plan_context"
require "hive/agent_profiles"
require "hive/stages/base"

module Hive
  module Reviewers
    # Native-`codex review` reviewer.
    #
    # Unlike Hive::Reviewers::Agent (which spawns `codex exec /ce-code-review`
    # and lets the agent WRITE the findings file itself), this adapter runs
    # codex's built-in `codex review` subcommand — a single tuned, read-only
    # code-review pass — and CAPTURES its stdout, then writes that stdout to
    # `reviews/<output_basename>-<pass>.md`. It is the patrol-default reviewer:
    # one cheap pass instead of the multi-persona ce-code-review fan-out.
    #
    # Why a custom PROMPT instead of `--base`:
    #   `codex review --base <BRANCH>` works, but the codex CLI's argument
    #   parser makes `--base` MUTUALLY EXCLUSIVE with a custom `[PROMPT]`
    #   ("the argument '--base <BRANCH>' cannot be used with '[PROMPT]'").
    #   The native `--base` review emits codex's own free-form summary, NOT
    #   Hive's GFM-checkbox findings format, so it can't feed the triage/fix
    #   loop unchanged. We therefore use the custom-PROMPT mode and have the
    #   prompt itself (a) scope the review to `git diff <base>...HEAD` and
    #   (b) coerce the High/Medium/Nit checkbox output. argv is
    #   `[codex, "review", "--title", <title>, <prompt>]`.
    #
    # Token usage: `codex review` emits a human-readable transcript on stdout
    # with no machine-parseable per-token usage event (that only exists for
    # `codex exec --json`). We therefore intentionally do NOT record usage —
    # fabricating zeros would pollute UsageDb. If a future codex release adds
    # a usage line to `codex review`, wire it through Base.record_usage here.
    class CodexReview < Base
      # Reuse Agent's per-reviewer wall-clock default (2h) so a config that
      # omits timeout_sec behaves identically across reviewer kinds.
      DEFAULT_TIMEOUT_SEC = 7200

      # Cap captured stdout so a runaway review can't OOM the host. A real
      # review is a few KB; 4 MiB is generous headroom.
      MAX_OUTPUT_BYTES = 4 * 1024 * 1024

      # Findings file is valid only if it contains at least one severity
      # header. Anything else (banner-only output, an interrupted run, a
      # usage-limit error) is treated as a reviewer failure.
      SEVERITY_HEADER = /^##\s+(High|Medium|Nit)\b/i.freeze

      def initialize(spec, ctx, cfg: nil)
        super(spec, ctx)
        @cfg = cfg
      end

      def run!(deadline: nil)
        ensure_reviews_dir!

        profile = Hive::AgentProfiles.lookup(spec.fetch("agent"), cfg: @cfg)
        begin
          profile.check_version!
        rescue Hive::AgentError => e
          return error_result("preflight failed: #{e.message}")
        end

        prompt = render_prompt
        configured_timeout = spec["timeout_sec"] || DEFAULT_TIMEOUT_SEC
        max_attempts = max_attempts_from_spec

        attempts = 0
        run = nil
        loop do
          attempts += 1
          # Clear any partial file from a prior crashed attempt so a stale
          # file can't satisfy this attempt's format check.
          delete_output!

          spawn_timeout = effective_timeout(configured_timeout, deadline)
          if spawn_timeout && spawn_timeout <= 0
            return error_result("deadline reached before attempt #{attempts}", attempts, max_attempts)
          end

          run = run_codex_review(profile.bin, prompt, spawn_timeout || configured_timeout)
          break if run.success? && valid_findings?(run.stdout)
          break if attempts >= max_attempts

          sleep_seconds = backoff_seconds_for(attempts)
          if deadline
            remaining = deadline_remaining(deadline)
            break if remaining <= 0

            sleep_seconds = [ sleep_seconds, remaining ].min
          end
          backoff(sleep_seconds)
        end

        finalize(run, attempts, max_attempts)
      end

      private

      # Captured-process result. exit_code is nil on launch failure / timeout.
      Run = Struct.new(:stdout, :exit_code, :error) do
        def success?
          error.nil? && exit_code&.zero? || false
        end
      end

      def finalize(run, attempts, max_attempts)
        if run && run.success? && valid_findings?(run.stdout)
          File.write(output_path, normalize_output(run.stdout))
          return Result.new(name: name, output_path: output_path, status: :ok, error_message: nil)
        end

        # Failure: leave no malformed findings file behind — triage would
        # otherwise treat it as real reviewer output.
        delete_output!
        error_result(failure_message(run), attempts, max_attempts)
      end

      def failure_message(run)
        return "codex review produced no output" if run.nil?
        return run.error if run.error
        unless run.exit_code&.zero?
          return "codex review exited with status=#{run.exit_code.inspect}"
        end

        "codex review output missing High/Medium/Nit findings headers"
      end

      def error_result(base_msg, attempts = nil, max_attempts = nil)
        msg =
          if attempts && max_attempts && max_attempts > 1
            "#{base_msg} after #{attempts} attempt(s)"
          else
            base_msg
          end
        Result.new(name: name, output_path: output_path, status: :error, error_message: msg)
      end

      def valid_findings?(stdout)
        stdout.to_s.match?(SEVERITY_HEADER)
      end

      # Trim leading codex banner noise so the published findings file starts
      # at the first severity header. Everything from the first `## High|
      # Medium|Nit` onward is the model's structured output.
      def normalize_output(stdout)
        text = stdout.to_s
        idx = text =~ SEVERITY_HEADER
        body = idx ? text[idx..] : text
        body = body.rstrip
        body.empty? ? body : "#{body}\n"
      end

      # Run `codex review --title <title> <prompt>` in the worktree, capturing
      # combined stdout+stderr with a wall-clock timeout. On timeout the
      # process group is signalled so a hung review can't outlive the budget.
      #
      # The codex binary's existence is already proven by `check_version!`
      # (the caller's preflight), so a spawn-time ENOENT is unreachable here
      # — we deliberately do not re-rescue it.
      def run_codex_review(bin, prompt, timeout_sec)
        argv = [ bin, "review", "--title", review_title, prompt ]

        pipe_r, pipe_w = IO.pipe
        pid = Process.spawn(*argv, chdir: ctx.worktree_path, pgroup: true, out: pipe_w, err: pipe_w)
        pipe_w.close

        capture_run(pipe_r, pid, timeout_sec)
      end

      def capture_run(pipe_r, pid, timeout_sec)
        reader = Thread.new { pipe_r.read(MAX_OUTPUT_BYTES) }

        status = wait_with_timeout(pid, timeout_sec)
        if status.nil?
          terminate(pid)
          reader.join(2)
          reader.kill if reader.alive?
          pipe_r.close unless pipe_r.closed?
          return Run.new(nil, nil, "codex review timed out after #{timeout_sec}s")
        end

        combined = reader.value.to_s
        pipe_r.close unless pipe_r.closed?
        combined = combined.dup.force_encoding(Encoding::UTF_8)
        combined.scrub!("?")
        Run.new(combined, status.exitstatus, nil)
      end

      # Poll for the child to exit, returning its Process::Status, or nil if
      # `timeout_sec` elapses first.
      def wait_with_timeout(pid, timeout_sec)
        deadline = Time.now + timeout_sec
        loop do
          _, status = Process.wait2(pid, Process::WNOHANG)
          return status if status
          return nil if Time.now > deadline

          sleep 0.05
        end
      end

      # TERM the child's process group (best-effort), then reap it. The
      # short KILL escalation is intentionally omitted — codex review is
      # read-only and TERM-clean; the reader-thread join + pipe close bound
      # the wait regardless.
      def terminate(pid)
        Process.kill("TERM", -Process.getpgid(pid))
      rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
        nil
      ensure
        reap(pid)
      end

      def reap(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      # Short, deterministic title for the review summary. codex truncates
      # long titles; keep it to the project + pass.
      def review_title
        "hive patrol review: #{File.basename(ctx.worktree_path)} pass #{ctx.pass}"
      end

      def render_prompt
        template_path = Hive::Stages::Base.resolve_template_path(
          spec.fetch("prompt_template"),
          hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
        )
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
            user_supplied_tag: tag,
            plan_context_section: Hive::Reviewers::PlanContext.render(ctx.task_folder, tag)
          )
        )
      end

      def max_attempts_from_spec
        value = spec["max_attempts"]
        return Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS if value.nil?

        Integer(value)
      rescue ArgumentError
        warn "[hive.reviewers] reviewer #{spec['name'].inspect}: invalid max_attempts " \
             "#{value.inspect}; using default #{Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS}"
        Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS
      end

      def backoff_seconds_for(failed_attempt)
        [ 2**(failed_attempt - 1), Hive::Reviewers::REVIEWER_BACKOFF_CAP_SEC ].min
      end

      def backoff(seconds)
        sleep(seconds)
      end

      def deadline_remaining(deadline)
        deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def effective_timeout(configured_timeout, deadline)
        return configured_timeout unless deadline

        remaining = deadline_remaining(deadline)
        return remaining.floor if remaining <= 0

        [ configured_timeout, remaining.floor ].min
      end

      def delete_output!
        File.delete(output_path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Hive::Error,
              "reviewer #{name.inspect}: failed to clear partial output_path #{output_path}: " \
              "#{e.class}: #{e.message}"
      end
    end
  end
end
