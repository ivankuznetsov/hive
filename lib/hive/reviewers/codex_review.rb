require "hive/reviewers/base"
require "hive/reviewers/plan_context"
require "hive/reviewers/synthetic_task"
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
      # spells findings as `- [ ] <finding>: <one-line justification>`. codex
      # ALWAYS echoes the prompt (including this example) at the top of its
      # session transcript, so the RAW stdout almost always contains this
      # placeholder even for a genuine review. The check therefore runs against
      # codex's real answer (see #review_body) with the echoed prompt stripped —
      # a placeholder surviving there means codex's OWN answer is the unfilled
      # template (a hollow run): fail so it retries instead of recording a fake
      # clean pass.
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
      # `review_body` drops; `CODEX_REPLY` is the final-message marker.
      SESSION_MARKER = /\A(?:exec|thinking|codex)\z/.freeze
      CODEX_REPLY = /\Acodex\z/.freeze

      # Canonical clean-pass findings, in the exact shape the prompt asks for an
      # empty review ("No findings." under each header). Published when codex
      # genuinely reviewed but produced a prose verdict with no structured
      # findings — so triage sees a well-formed zero-finding file instead of the
      # whole pass failing as all_failed.
      CLEAN_FINDINGS = "## High\nNo findings.\n\n## Medium\nNo findings.\n\n## Nit\nNo findings.\n".freeze

      # codex sometimes answers a clean review in PROSE instead of the strict
      # checkbox format (especially for patrol PRs, where it leads with "no plan
      # was found"). We accept such a verdict as a clean pass ONLY when it
      # AFFIRMATIVELY says nothing was found (matches CLEAN_VERDICT and NOT
      # CONCERN_SIGNAL). Otherwise an arbitrary non-empty reply — a
      # prose-described bug, or a soft-error like "stream error, unable to
      # complete the review" — would be silently laundered into a "No findings."
      # pass. A reply matching neither findings nor a clean verdict fails so it
      # retries / fails loudly rather than masking a real finding.
      # Phrasings covered: "did not find", "found no/nothing", "no <...>
      # regressions/findings/issues/bugs", "nothing to flag/fix/report", and
      # "the diff is/looks clean".
      CLEAN_VERDICT = /
        did\s*n.?t\s+find
        | found\s+(?:no\b|nothing\b)
        | \bno\b[^.\n]{0,60}?\b(?:regressions?|findings?|issues?|bugs?|problems?|defects?|concerns?|vulnerabilit\w*)
        | nothing\s+(?:to\s+(?:flag|fix|report|raise|address)|of\s+concern|stood\s+out)
        | (?:diff|change|branch|pr|code)\s+(?:is|looks?)\s+clean
      /xi.freeze

      # If codex's verdict carries any of these it is flagging something, so a
      # prose reply is NOT a safe clean pass even when it also contains a "no X"
      # phrase (e.g. "no major issues except a SQL injection"). Forces retry/fail.
      CONCERN_SIGNAL = /
        \b(?:vulnerabilit\w*|injection|data[\s-]*loss|race\s+condition|deadlock
        |high[\s-]severity|critical\s+(?:bug|issue|finding|vulnerabilit\w*)
        |(?:should|must|needs?\s+to)\s+(?:be\s+)?(?:fix|address|resolv|chang)\w*
        |introduces?\s+a\s+(?:bug|regression|vulnerabilit\w*|race)
        |i\s+found\s+(?:a|an|\d|several|multiple|some)
        |this\s+(?:is|introduces|causes)\s+a\s+(?:bug|regression))\b
      /xi.freeze

      # codex-cli's native `codex review` output — emitted when it ignores the
      # custom prompt's GFM coercion, notably on the "No plan was found" patrol
      # path — lists findings as priority-tagged bullets instead of the
      # `## High/Medium/Nit` checkboxes the prompt asks for, e.g.
      #   - [P1] <title> — <path>:<line>
      #       <indented justification…>
      # A line is a native finding when it is (optionally bulleted) `[Pn]` text.
      # We normalize these into the canonical checkbox block so a real codex
      # finding feeds triage instead of failing the whole pass as `all_failed`.
      NATIVE_FINDING = /\A\s*[-*]?\s*\[P(\d)\]\s*(.+?)\s*\z/.freeze

      # codex priority → Hive severity. P1 (and a defensive P0) is High, P2 is
      # Medium, everything lower (P3+) is Nit.
      NATIVE_SEVERITY = { 0 => "High", 1 => "High", 2 => "Medium" }.freeze

      def initialize(spec, ctx, cfg: nil)
        super(spec, ctx)
        @cfg = cfg
      end

      def run!(deadline: nil)
        ensure_reviews_dir!

        profile = Hive::AgentProfiles.lookup(spec.fetch("agent"), cfg: @cfg)
        # A8 fail-closed gate. codex_review ALWAYS runs a non-claude runner
        # (`codex review`), which cannot enforce tool scoping. A reviewer that
        # declares a non-yolo `permissions:` (which load-validation accepts as
        # a valid reviewer entry) therefore can't be honored — resolve the
        # scope so PermissionScope.resolve raises Hive::ConfigError on a
        # non-yolo spec, the same hard error the agent adapter triggers,
        # instead of silently running `codex review` unscoped. The resolved
        # scope is intentionally discarded: `codex review` is inherently
        # read-only and takes no tool-list args, so only the gate matters.
        enforce_permission_scope_gate!(profile)
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

      # Resolve this reviewer's permission scope purely for its A8 side
      # effect: PermissionScope.resolve raises Hive::ConfigError when a
      # non-yolo spec lands on a runner that can't enforce tool scoping
      # (codex_review is always such a runner). Mirrors the agent adapter's
      # scope kwargs so an explicit per-reviewer `permissions:` and the
      # project default resolve through the same "review.reviewers" path.
      def enforce_permission_scope_gate!(profile)
        Hive::Stages::Base.stage_permission_scope(
          @cfg || {}, "review.reviewers", synthetic_task, profile,
          base_add_dirs: [ ctx.task_folder ],
          **Hive::Stages::Base.explicit_permission_kwargs(spec)
        )
        nil
      end

      def synthetic_task
        Hive::Reviewers.synthetic_task_for(ctx)
      end

      # Captured-process result. exit_code is nil on launch failure / timeout.
      Run = Struct.new(:stdout, :exit_code, :error) do
        def success?
          error.nil? && exit_code&.zero? || false
        end
      end

      def finalize(run, attempts, max_attempts)
        case review_status(run)
        when :findings
          File.write(output_path, format_body(findings_markdown(review_body(run.stdout))))
          Result.new(name: name, output_path: output_path, status: :ok, error_message: nil)
        when :clean
          File.write(output_path, clean_findings(review_body(run.stdout)))
          Result.new(name: name, output_path: output_path, status: :ok, error_message: nil)
        else
          # Failure: leave no malformed findings file behind — triage would
          # otherwise treat it as real reviewer output.
          delete_output!
          error_result(base_reason(run), attempts, max_attempts, detail: captured_tail(run))
        end
      end

      # A run is usable when codex's real answer is either structured findings
      # or a genuine no-findings verdict. The run! loop breaks on this.
      def usable_review?(run)
        status = review_status(run)
        status == :findings || status == :clean
      end

      # Classify codex's REAL answer (the echoed prompt + tool transcript
      # stripped — see #review_body):
      #   :findings      — carries ## High/Medium/Nit findings → publish them
      #   :clean         — codex's prose verdict AFFIRMATIVELY reports no findings
      #                    (and flags no concern) → publish a canonical pass
      #   :template_echo — codex's own answer is the unfilled prompt template
      #   :error         — launch/timeout/non-zero exit, banner/interrupted
      #                    output, OR a prose reply that neither carries findings
      #                    nor clearly says "nothing found" (retry/fail loudly
      #                    rather than mask a prose-described finding)
      def review_status(run)
        return :error unless run&.success?

        body = review_body(run.stdout)
        return :template_echo if template_echo?(body)
        return :findings if valid_findings?(body)
        return :findings if native_findings?(body)
        return :clean if clean_verdict?(body)

        :error
      end

      # Terse, single-line failure reason (no captured output — `captured_tail`
      # carries that). Order matters: a non-zero exit is reported as such even
      # when stdout happens to echo the template.
      def base_reason(run)
        return "codex review produced no output" if run.nil?
        return run.error if run.error
        return "codex review exited with status=#{run.exit_code.inspect}" unless run.exit_code&.zero?
        return "codex review echoed the prompt template instead of producing findings" if echoed_template?(run)

        "codex review output missing High/Medium/Nit findings headers"
      end

      # True when codex's real answer is the unfilled template, or when nothing
      # but the echoed prompt template survived (a hollow run with no verdict).
      def echoed_template?(run)
        body = review_body(run.stdout)
        template_echo?(body) || (body.empty? && template_echo?(run.stdout))
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

      # The findings markdown to publish: codex's own GFM block when it already
      # carries `## High/Medium/Nit` headers, else its native `[Pn]` bullets
      # normalized into that format so triage's `- [ ]` parser can consume them.
      def findings_markdown(body)
        return body if body.to_s.match?(SEVERITY_HEADER)

        normalize_native_findings(body)
      end

      # True when codex's real answer carries at least one native priority
      # finding (`- [P1] …`) and no `## High/Medium/Nit` header — the format we
      # normalize rather than reject as a missing-header failure.
      def native_findings?(body)
        text = body.to_s
        return false if text.match?(SEVERITY_HEADER)

        text.each_line.any? { |line| NATIVE_FINDING.match?(line) }
      end

      # Fold codex's native `[Pn]` bullets into the canonical
      # `## High/Medium/Nit` checkbox block. Each finding's indented
      # justification lines are joined onto its single checkbox line; identical
      # findings (codex sometimes echoes the same one twice) are de-duplicated;
      # a severity with no findings still prints its header + `No findings.` so
      # the published file matches the prompt's three-header contract.
      def normalize_native_findings(body)
        buckets = { "High" => [], "Medium" => [], "Nit" => [] }
        current = nil
        body.to_s.each_line do |line|
          if (m = NATIVE_FINDING.match(line))
            current = [ m[2].strip ]
            buckets[NATIVE_SEVERITY.fetch(m[1].to_i, "Nit")] << current
          elsif current && line.match?(/\A\s+\S/)
            current << line.strip
          else
            current = nil
          end
        end
        render_native_findings(buckets)
      end

      def render_native_findings(buckets)
        seen = {}
        sections = buckets.map do |severity, findings|
          lines = findings.filter_map do |parts|
            text = parts.join(" ").gsub(/\s+/, " ").strip
            next if text.empty? || seen[text]

            seen[text] = true
            text = "#{text[0, 500].rstrip}…" if text.length > 500
            "- [ ] #{text}"
          end
          lines << "No findings." if lines.empty?
          "## #{severity}\n#{lines.join("\n")}"
        end
        "#{sections.join("\n\n")}\n"
      end

      def template_echo?(stdout)
        stdout.to_s.match?(TEMPLATE_ECHO)
      end

      # codex's REAL review answer, with the echoed prompt AND the exec/thinking
      # tool transcript stripped. codex review streams: [banner][echoed prompt,
      # carrying the template's own "## High / - [ ] <finding>:..." example]
      # [thinking/exec transcript][final assistant message]. We keep a leading
      # findings block ONLY when it is real (not the verbatim placeholder
      # template) plus codex's final message — so the raw prompt echo never
      # drives the usable/echo decision and never bloats the published file.
      # (Handing triage the raw transcript, seen at 96 KB–565 KB, has timed it
      # out.)
      def review_body(stdout)
        text = stdout.to_s
        idx = text =~ SEVERITY_HEADER
        body = idx ? text[idx..] : text
        head, reply = split_session_transcript(body)
        head = "" if template_echo?(head) # the echoed prompt example, not findings
        [ head.rstrip, reply.strip ].reject(&:empty?).join("\n\n")
      end

      # Split a (header-leading) body into the leading findings block and
      # codex's final assistant message, discarding the exec/thinking/codex
      # transcript between them. No session marker → it is all "head" (an
      # already-clean output, or a shape we don't recognize — never worse than
      # the raw body).
      def split_session_transcript(body)
        lines = body.lines
        first = lines.index { |line| line.chomp.match?(SESSION_MARKER) }
        return [ body, "" ] unless first

        last_reply = lines.rindex { |line| line.chomp.match?(CODEX_REPLY) }
        head = lines[0...first].join
        reply = last_reply && last_reply >= first ? lines[(last_reply + 1)..].join : ""
        [ head, reply ]
      end

      # Does codex's real answer AFFIRMATIVELY report a clean review — a "no
      # findings / no regressions / diff is clean" verdict with no concern
      # signal? Anything else (a prose-described finding, a soft-error/abort
      # message, banner-only output) returns false so it fails/retries instead
      # of being silently recorded as a clean pass.
      def clean_verdict?(body)
        text = body.to_s
        return false if text.strip.empty?

        CLEAN_VERDICT.match?(text) && !CONCERN_SIGNAL.match?(text)
      end

      def format_body(body)
        body.empty? ? body : "#{body}\n"
      end

      # codex reviewed and gave a prose verdict with no structured findings:
      # publish the canonical clean pass, preserving codex's verdict as a
      # single-line trailing comment for the audit trail (triage parses
      # `- [ ]` checkbox lines, so an inert one-line HTML comment is ignored).
      def clean_findings(body)
        note = body.gsub(/\s+/, " ").delete("<>").strip
        return CLEAN_FINDINGS if note.empty?

        note = "#{note[0, 500].rstrip}…" if note.length > 500
        "#{CLEAN_FINDINGS}\n<!-- codex review summary: #{note} -->\n"
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
        Hive::Reviewers.backoff_seconds_for(failed_attempt)
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
