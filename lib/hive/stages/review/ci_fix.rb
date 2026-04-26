require "open3"
require "fileutils"
require "shellwords"
require "hive/agent_profiles"
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

        module_function

        def run!(cfg:, ctx:)
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

          attempts = 0
          last_output = nil

          loop do
            attempts += 1
            run_result = run_ci_once(command, ctx.worktree_path, max_bytes)
            return run_result.to_result(attempts: attempts) if run_result.is_a?(CommandError)

            output = clean_output(run_result.combined, tail_lines)
            last_output = output

            return Result.new(
              status: :green,
              attempts: attempts,
              last_output: output,
              error_message: nil
            ) if run_result.exit_code.zero?

            if attempts >= max_attempts
              return Result.new(
                status: :stale,
                attempts: attempts,
                last_output: output,
                error_message: nil
              )
            end

            spawn_result = spawn_fix_agent(
              cfg: cfg,
              ctx: ctx,
              command: command,
              attempt: attempts,
              max_attempts: max_attempts,
              captured_output: output
            )
            if spawn_result[:status] != :ok
              return Result.new(
                status: :error,
                attempts: attempts,
                last_output: output,
                error_message: spawn_result[:error_message] || "fix agent failed (#{spawn_result[:status]})"
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

        # Run the CI command once, capturing combined stdout+stderr up
        # to max_bytes. Returns a struct so the caller can branch on
        # error vs result before classifying as :green / :red.
        def run_ci_once(command, cwd, max_bytes)
          # Always exec directly — no `sh -c` indirection. A String
          # command is shellword-split (so `bin/ci --flag` works as
          # YAML); an Array is exec'd as-is (so paths with spaces or
          # injected args are safe). Direct exec means a missing
          # binary raises ENOENT cleanly instead of returning shell's
          # exit-127, letting the caller distinguish "binary doesn't
          # exist" from "CI ran but failed."
          cmd = command.is_a?(Array) ? command : Shellwords.split(command.to_s)
          if cmd.empty?
            return CommandError.new("CI command is empty after parsing")
          end

          begin
            stdout, stderr, status = Open3.capture3(*cmd, chdir: cwd, binmode: true)
          rescue Errno::ENOENT, Errno::EACCES => e
            return CommandError.new("CI command not runnable: #{cmd.first.inspect} (#{e.class.name.split('::').last}: #{e.message})")
          rescue StandardError => e
            return CommandError.new("CI command failed to launch: #{e.message}")
          end

          combined = stdout.to_s + stderr.to_s
          combined = combined.byteslice(-max_bytes, max_bytes) if combined.bytesize > max_bytes
          combined.force_encoding(Encoding::UTF_8)
          combined.scrub!("?") # replace invalid UTF-8 sequences

          Run.new(combined, status.exitstatus, false)
        end

        Run = Struct.new(:combined, :exit_code, :error_flag) do
          def error?
            error_flag
          end
        end

        # Wrap a launch failure as a Result :error directly so the
        # caller doesn't have to distinguish "command exited non-zero"
        # from "command couldn't even start."
        CommandError = Struct.new(:reason) do
          def error?
            true
          end

          def to_result(attempts: 0)
            CiFix::Result.new(
              status: :error,
              attempts: attempts,
              last_output: nil,
              error_message: reason
            )
          end
        end

        def spawn_fix_agent(cfg:, ctx:, command:, attempt:, max_attempts:, captured_output:)
          profile_name = cfg.dig("review", "ci", "agent") || "claude"
          profile = Hive::AgentProfiles.lookup(profile_name)

          template = cfg.dig("review", "ci", "prompt_template") || "ci_fix_prompt.md.erb"
          tag = Hive::Stages::Base.user_supplied_tag

          prompt = Hive::Stages::Base.render(
            template,
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
          SyntheticTask.new(
            folder: ctx.task_folder,
            state_file: File.join(ctx.task_folder, "task.md"),
            log_dir: File.join(ctx.task_folder, "logs"),
            stage_name: "5-review"
          )
        end

        SyntheticTask = Struct.new(:folder, :state_file, :log_dir, :stage_name, keyword_init: true)
      end
    end
  end
end
