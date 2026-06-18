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

      # Cap the bytes RETAINED from a runaway review so it can't OOM the
      # host. This is NOT a hard abort: the reader keeps draining the pipe
      # past the cap (discarding the overflow) so the child always reaches
      # EOF promptly and never blocks forever on a full pipe. A real review
      # is a few KB; 4 MiB is generous headroom.
      MAX_OUTPUT_BYTES = 4 * 1024 * 1024

      # Findings file is valid only if it contains at least one severity
      # header. Anything else (banner-only output, an interrupted run, a
      # usage-limit error) is treated as a reviewer failure.
      SEVERITY_HEADER = /^##\s+(High|Medium|Nit)\b/i.freeze

      # The prompt's example block (templates/reviewer_codex_native_review.md.erb)
      # spells findings as `- [ ] <finding>: <one-line justification>`. When
      # codex echoes the prompt template instead of reviewing, the output
      # carries the `## High/Medium/Nit` headers (so it passes SEVERITY_HEADER)
      # but still has these literal angle-bracket placeholders — a real review
      # never emits them. Treat that as a reviewer failure so it retries rather
      # than recording a hollow clean pass.
      TEMPLATE_ECHO = /-\s*\[\s*\]\s*<finding>:\s*<one-line justification>/.freeze

      # Bytes of the captured codex transcript retained in the failure message
      # (and thus in reviews/errors-NN.md) so an `all_failed` is diagnosable
      # instead of an opaque "exited status=1". codex prints its error near the
      # end before exiting, so the tail is where the cause lives. Surfacing it
      # also lets Hive::AgentLimit.limit_reached? — which only sees the error
      # message — catch a codex usage-limit and route the phase to the cooldown
      # path (limits_reached) instead of a generic all_failed.
      FAILURE_TAIL_BYTES = 2000

      # `codex review` streams its whole session to stdout: the (prompt-echoed)
      # findings block, then a tool-call transcript of bare `exec`/`thinking`/
      # `codex` section markers (each `exec` block can be hundreds of lines —
      # cat'd files, diffs, even a full test run), then codex's final
      # assistant message under the last `codex` marker. A bare line that is
      # exactly one of these markers delimits the transcript that
      # `normalize_output` drops; `CODEX_REPLY` is the final-message marker.
      SESSION_MARKER = /\A(?:exec|thinking|codex)\z/.freeze
      CODEX_REPLY = /\Acodex\z/.freeze

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
          break if usable_review?(run)
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
        if usable_review?(run)
          File.write(output_path, normalize_output(run.stdout))
          return Result.new(name: name, output_path: output_path, status: :ok, error_message: nil)
        end

        # Failure: leave no malformed findings file behind — triage would
        # otherwise treat it as real reviewer output.
        delete_output!
        error_result(base_reason(run), attempts, max_attempts, detail: captured_tail(run))
      end

      # A run is usable only when it exited 0, carries the severity headers, and
      # is NOT the prompt template echoed back (which would otherwise pass the
      # header check as a hollow clean pass).
      def usable_review?(run)
        return false unless run&.success?

        valid_findings?(run.stdout) && !template_echo?(run.stdout)
      end

      # Terse, single-line failure reason (no captured output — `captured_tail`
      # carries that). Order matters: a non-zero exit is reported as such even
      # when stdout happens to echo the template.
      def base_reason(run)
        return "codex review produced no output" if run.nil?
        return run.error if run.error
        return "codex review exited with status=#{run.exit_code.inspect}" unless run.exit_code&.zero?
        return "codex review echoed the prompt template instead of producing findings" if template_echo?(run.stdout)

        "codex review output missing High/Medium/Nit findings headers"
      end

      # The last FAILURE_TAIL_BYTES of codex's combined stdout+stderr, indented
      # under a labeled fence, appended to the failure message so it lands in
      # reviews/errors-NN.md. Returns "" when nothing was captured (launch
      # failure / timeout). codex's actual error sits at the end of the
      # transcript, so a tail captures it without bloating the errors file with
      # a multi-MB transcript.
      def captured_tail(run)
        text = run&.stdout.to_s
        return "" if text.empty?

        shown = [ FAILURE_TAIL_BYTES, text.bytesize ].min
        tail = text.byteslice(text.bytesize - shown, shown).to_s
        tail = tail.dup.force_encoding(Encoding::UTF_8)
        tail.scrub!("?")
        tail = tail.strip
        return "" if tail.empty?

        "\n  ── codex output (last #{shown} bytes) ──\n#{tail.gsub(/^/, '    ')}"
      end

      def error_result(base_msg, attempts = nil, max_attempts = nil, detail: nil)
        msg =
          if attempts && max_attempts && max_attempts > 1
            "#{base_msg} after #{attempts} attempt(s)"
          else
            base_msg
          end
        msg = "#{msg}#{detail}" if detail && !detail.empty?
        Result.new(name: name, output_path: output_path, status: :error, error_message: msg)
      end

      def valid_findings?(stdout)
        stdout.to_s.match?(SEVERITY_HEADER)
      end

      def template_echo?(stdout)
        stdout.to_s.match?(TEMPLATE_ECHO)
      end

      # Trim codex's stdout to the findings triage needs to read: drop the
      # leading banner (start at the first severity header) AND the tool-call
      # transcript in the middle, keeping the leading findings block plus
      # codex's final message. Handing triage the raw transcript (seen at
      # 96 KB–565 KB) bloats its prompt and has caused triage timeouts.
      def normalize_output(stdout)
        text = stdout.to_s
        idx = text =~ SEVERITY_HEADER
        body = idx ? text[idx..] : text
        body = drop_session_transcript(body).rstrip
        body.empty? ? body : "#{body}\n"
      end

      # Discard the `exec`/`thinking`/`codex` session transcript that sits
      # between the leading findings block and codex's final assistant message.
      # No session marker → return the body unchanged (already-clean output, or
      # a shape we don't recognize — never produce worse than the raw body).
      def drop_session_transcript(body)
        lines = body.lines
        first = lines.index { |line| line.chomp.match?(SESSION_MARKER) }
        return body unless first

        last_reply = lines.rindex { |line| line.chomp.match?(CODEX_REPLY) }
        head = lines[0...first].join.rstrip
        reply = last_reply && last_reply >= first ? lines[(last_reply + 1)..].join.strip : ""
        reply.empty? ? head : "#{head}\n\n#{reply}"
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
        # Drain the pipe FULLY in chunks but RETAIN at most MAX_OUTPUT_BYTES.
        # Reading exactly MAX_OUTPUT_BYTES and stopping would leave the pipe
        # full once a review emits more than the cap, blocking the child on
        # write() forever — the run would then only end at the wall-clock
        # timeout. Keep reading past the cap (discarding overflow) so EOF is
        # always reached and the child can exit promptly.
        reader = Thread.new do
          buf = +"".b
          while (chunk = pipe_r.read(65_536))
            buf << chunk if buf.bytesize < MAX_OUTPUT_BYTES
          end
          buf.byteslice(0, MAX_OUTPUT_BYTES)
        end

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

      # TERM the child's process group (best-effort), give it a short grace,
      # then KILL the group if anything in it is still alive before reaping.
      # codex review is normally TERM-clean, but a wedged child (e.g. stuck
      # in uninterruptible IO or ignoring TERM) would otherwise keep the pipe
      # write-end open and stall the reader join; the KILL escalation
      # guarantees the group is torn down.
      def terminate(pid)
        pgid = Process.getpgid(pid)
        Process.kill("TERM", -pgid)
        sleep 1
        Process.kill("KILL", -pgid) if process_group_alive?(pgid)
      rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
        nil
      ensure
        reap(pid)
      end

      # Best-effort liveness probe for a process group. `Process.kill(0, ...)`
      # signals nothing but raises ESRCH when no process in the group exists,
      # so a clean return means the group still has at least one member.
      def process_group_alive?(pgid)
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH, Errno::ECHILD
        false
      rescue Errno::EPERM
        # The group exists but we lack permission to signal it — treat as
        # alive so the KILL attempt still fires (and is itself guarded).
        true
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
