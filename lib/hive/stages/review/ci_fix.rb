require "open3"
require "fileutils"
require "shellwords"
require "digest"
require "hive/agent_profiles"
require "hive/protected_files"
require "hive/reviewers/synthetic_task"
require "hive/stages/base"

module Hive
  module Stages
    module Review
      # CI-fix loop for the 5-review stage.
      #
      # Runs the project's local CI command (review.ci.command) and, on
      # failure, spawns a fix agent with the captured failure log so the
      # agent can read the error, edit the offending files, commit, and
      # let the loop re-run CI. Loops up to review.ci.max_attempts.
      # After the cap, returns :stale; the U9 runner writes
      # reviews/ci-blocked.md with the final failure log and sets
      # REVIEW_CI_STALE — reviewers do NOT run on red CI per the plan's
      # hard-block contract.
      #
      # Hive does NOT know what the project's CI does. The user owns the
      # `bin/ci` (or `bin/rails test`, or `npm run check`, or whatever)
      # contract; hive shells out and parses exit code + last-N lines of
      # combined stdout+stderr. ANSI color codes are stripped before
      # tailing so the agent sees plain text. This keeps hive
      # ecosystem-agnostic while letting projects pick their own
      # tooling.
      module CiFix
        Result = Data.define(:status, :attempts, :last_output, :error_message)

        # ANSI escape sequence regex — matches CSI sequences (ESC [ ... letter)
        # which cover colors, cursor movement, text styling. Some CI
        # tools (rspec, jest, cargo) emit these by default even when
        # stdout isn't a TTY.
        ANSI_RE = /\e\[[0-9;]*[a-zA-Z]/

        DEFAULT_TAIL_LINES = 200
        DEFAULT_MAX_LOG_BYTES = 256 * 1024 # 256 KB hard cap on captured output
        PROTECTED_FILES = Hive::ProtectedFiles::ORCHESTRATOR_OWNED

        module_function

        def run!(cfg:, ctx:, started_at: nil, max_wall_clock_sec: nil)
          command = cfg.dig("review", "ci", "command")
          if command.nil? || command.to_s.strip.empty?
            return Result.new(
              status: :skipped,
              attempts: 0,
              last_output: nil,
              error_message: nil
            )
          end

          max_attempts = cfg.dig("review", "ci", "max_attempts") || 3
          tail_lines = cfg.dig("review", "ci", "tail_lines") || DEFAULT_TAIL_LINES
          max_bytes = cfg.dig("review", "ci", "max_log_bytes") || DEFAULT_MAX_LOG_BYTES
          # Per-attempt timeout for the CI subprocess itself. Reuses the
          # same review_ci budget that gates fix-agent spawns; a single
          # knob covers both halves of the loop. Default 600s matches
          # Config::DEFAULTS.timeout_sec.review_ci.
          timeout_sec = cfg.dig("timeout_sec", "review_ci") || 600

          attempts = 0
          last_output = nil

          loop do
            # DP2: enforce the runner's wall-clock cap between attempts so
            # a slow CI command can't blow the per-task budget. Skip the
            # check on attempt 1 — at least one CI invocation is always
            # allowed once we've decided to enter the loop.
            if attempts.positive? && started_at && max_wall_clock_sec &&
               (Time.now - started_at) >= max_wall_clock_sec
              return Result.new(
                status: :stale,
                attempts: attempts,
                last_output: last_output,
                error_message: "wall_clock_exceeded"
              )
            end

            attempts += 1
            run_result = run_ci_once(command, ctx.worktree_path, max_bytes, timeout_sec)
            return run_result.to_result(attempts: attempts) if run_result.is_a?(CommandError)

            output = clean_output(run_result.combined, tail_lines)
            last_output = output

            # exit_code can be nil when the subprocess was killed by a
            # signal (e.g., SIGPIPE after the reader hit max_bytes and
            # closed the pipe). Treat nil as non-zero so the loop falls
            # through to the :stale / fix-agent path; only a clean
            # exit-0 counts as :green.
            return Result.new(
              status: :green,
              attempts: attempts,
              last_output: output,
              error_message: nil
            ) if run_result.exit_code && run_result.exit_code.zero?

            if attempts >= max_attempts
              return Result.new(
                status: :stale,
                attempts: attempts,
                last_output: output,
                error_message: nil
              )
            end

            before = Hive::ProtectedFiles.snapshot(ctx.task_folder, PROTECTED_FILES)
            spawn_result = spawn_fix_agent(
              cfg: cfg,
              ctx: ctx,
              command: command,
              attempt: attempts,
              max_attempts: max_attempts,
              captured_output: output
            )
            after = Hive::ProtectedFiles.snapshot(ctx.task_folder, PROTECTED_FILES)
            tampered = Hive::ProtectedFiles.diff(before, after)
            if tampered.any?
              return Result.new(
                status: :error,
                attempts: attempts,
                last_output: output,
                error_message: "ci fix agent modified protected files: #{tampered.join(', ')}"
              )
            end

            if spawn_result[:status] != :ok
              return Result.new(
                status: :error,
                attempts: attempts,
                last_output: output,
                error_message: spawn_result[:error_message] || "fix agent failed (#{spawn_result[:status]})"
              )
            end

            if git_worktree?(ctx.worktree_path) && worktree_dirty?(ctx.worktree_path)
              return Result.new(
                status: :error,
                attempts: attempts,
                last_output: output,
                error_message: "ci fix agent left uncommitted worktree changes"
              )
            end
          end
        end

        # Strip ANSI color codes and trailing whitespace, then take the
        # last `tail_lines` lines. Most agent prompts have a token
        # budget; sending megabytes of CI log fails the spawn.
        def clean_output(raw, tail_lines)
          stripped = raw.to_s.gsub(ANSI_RE, "")
          lines = stripped.lines
          return stripped if lines.size <= tail_lines

          tail = lines.last(tail_lines).join
          truncated_count = lines.size - tail_lines
          "[... #{truncated_count} earlier lines truncated; showing last #{tail_lines} ...]\n#{tail}"
        end

        # Run the CI command once with a per-attempt timeout, streaming
        # combined stdout+stderr through a pipe and capping at max_bytes
        # *during* the read so a runaway CI command can't OOM the host.
        # On timeout the subprocess group is TERM'd then KILL'd (same
        # pattern as Hive::Agent#spawn_and_wait) and a CommandError is
        # returned so the caller's :error path covers it.
        def run_ci_once(command, cwd, max_bytes, timeout_sec)
          # Always exec directly — no `sh -c` indirection. A String
          # command is shellword-split (so `bin/ci --flag` works as
          # YAML); an Array is exec'd as-is (so paths with spaces or
          # injected args are safe). Direct exec means a missing
          # binary raises ENOENT cleanly instead of returning shell's
          # exit-127, letting the caller distinguish "binary doesn't
          # exist" from "CI ran but failed."
          cmd = command.is_a?(Array) ? command : Shellwords.split(command.to_s)
          return CommandError.new("CI command is empty after parsing") if cmd.empty?

          begin
            pipe_r, pipe_w = IO.pipe
            pid = Process.spawn(*cmd, chdir: cwd, pgroup: true, out: pipe_w, err: pipe_w)
            pipe_w.close
          rescue Errno::ENOENT, Errno::EACCES => e
            pipe_r&.close unless pipe_r&.closed?
            pipe_w&.close unless pipe_w&.closed?
            return CommandError.new(
              "CI command not runnable: #{cmd.first.inspect} " \
              "(#{e.class.name.split('::').last}: #{e.message})"
            )
          rescue StandardError => e
            pipe_r&.close unless pipe_r&.closed?
            pipe_w&.close unless pipe_w&.closed?
            return CommandError.new("CI command failed to launch: #{e.message}")
          end

          combined = +""
          # Reader keeps draining the pipe so the producer doesn't block
          # or die with SIGPIPE, but appends only up to max_bytes into
          # the captured buffer. Once the cap is hit we read-and-drop
          # remaining bytes — bound memory, clean subprocess exit. The
          # downstream consumer tail-truncates by line count in
          # clean_output.
          reader = Thread.new do
            buf = +""
            capped = false
            loop do
              chunk = pipe_r.read_nonblock(4096, exception: false)
              if chunk == :wait_readable
                IO.select([ pipe_r ], nil, nil, 0.1)
                next
              end
              break if chunk.nil?

              next if capped

              remaining = max_bytes - buf.bytesize
              if remaining <= 0
                capped = true
                next
              end

              buf << (chunk.bytesize > remaining ? chunk.byteslice(0, remaining) : chunk)
            end
            combined.replace(buf)
          rescue EOFError, IOError
            nil
          ensure
            pipe_r.close unless pipe_r.closed?
          end

          pgid = begin
            Process.getpgid(pid)
          rescue Errno::ESRCH
            pid
          end

          deadline = Time.now + timeout_sec
          status = nil
          loop do
            if Time.now > deadline
              kill_process_group(pgid, pid)
              reader.join(2)
              reader.kill if reader.alive?
              return CommandError.new("CI command timed out after #{timeout_sec}s")
            end
            _, status = Process.wait2(pid, Process::WNOHANG)
            break if status

            sleep 0.1
          end
          reader.join(2)
          reader.kill if reader.alive?

          combined.force_encoding(Encoding::UTF_8)
          combined.scrub!("?") # replace invalid UTF-8 sequences

          Run.new(combined, status.exitstatus)
        end

        # TERM the process group, give it 3s to drain, then KILL.
        # Mirrors Hive::Agent#sleep_grace_then_kill so a hung CI
        # subprocess can't survive the timeout window.
        def kill_process_group(pgid, pid)
          begin
            Process.kill("TERM", -pgid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
          grace_deadline = Time.now + 3
          until Time.now >= grace_deadline
            reaped =
              begin
                Process.wait(pid, Process::WNOHANG)
              rescue Errno::ECHILD
                pid
              end
            return if reaped

            sleep 0.1
          end
          begin
            Process.kill("KILL", -pgid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            nil
          end
        end

        Run = Struct.new(:combined, :exit_code)

        # Wrap a launch failure as a Result :error directly so the
        # caller doesn't have to distinguish "command exited non-zero"
        # from "command couldn't even start."
        CommandError = Struct.new(:reason) do
          def to_result(attempts: 0)
            CiFix::Result.new(
              status: :error,
              attempts: attempts,
              last_output: nil,
              error_message: reason
            )
          end
        end

        def git_worktree?(path)
          _out, _err, status = Open3.capture3("git", "-C", path, "rev-parse", "--is-inside-work-tree")
          status.success?
        end

        def worktree_dirty?(path)
          out, _err, status = Open3.capture3("git", "-C", path, "status", "--porcelain")
          status.success? && !out.empty?
        end

        def spawn_fix_agent(cfg:, ctx:, command:, attempt:, max_attempts:, captured_output:)
          profile_name = cfg.dig("review", "ci", "agent") || "claude"
          profile = Hive::AgentProfiles.lookup(profile_name, cfg: cfg)

          template = cfg.dig("review", "ci", "prompt_template") || "ci_fix_prompt.md.erb"
          template_path = Hive::Stages::Base.resolve_template_path(
            template,
            hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
          )
          tag = Hive::Stages::Base.user_supplied_tag

          prompt = Hive::Stages::Base.render_resolved_path(
            template_path,
            Hive::Stages::Base::TemplateBindings.new(
              project_name: File.basename(ctx.worktree_path),
              worktree_path: ctx.worktree_path,
              task_folder: ctx.task_folder,
              task_slug: File.basename(ctx.task_folder),
              command: Array(command).join(" "),
              attempt: attempt,
              max_attempts: max_attempts,
              captured_output: captured_output,
              user_supplied_tag: tag
            )
          )

          Hive::Stages::Base.spawn_agent(
            synthetic_task(ctx),
            prompt: prompt,
            add_dirs: [ ctx.task_folder ],
            cwd: ctx.worktree_path,
            max_budget_usd: cfg.dig("budget_usd", "review_ci") || 25,
            timeout_sec: cfg.dig("timeout_sec", "review_ci") || 600,
            log_label: "review-ci-fix-attempt#{format('%02d', attempt)}",
            profile: profile,
            status_mode: :exit_code_only
          )
        end

        def synthetic_task(ctx)
          Hive::Reviewers.synthetic_task_for(ctx)
        end
      end
    end
  end
end
