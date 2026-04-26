require "json"
require "fileutils"
require "hive/agent_profiles"
require "hive/reviewers/synthetic_task"
require "hive/stages/base"

module Hive
  module Stages
    module Review
      # Browser-test phase of the 5-review autonomous loop.
      #
      # Optional. Skipped entirely when `review.browser_test.enabled` is
      # false (default). When enabled, runs after Phase 2 produced zero
      # findings and before the runner finalizes. Spawns a configurable
      # agent (typically claude with the /ce-test-browser skill) up to
      # `review.browser_test.max_attempts` times. Each attempt is
      # expected to write `reviews/browser-result-<pass>-<attempt>.json`
      # with `{status: "passed"|"failed", summary, details, duration_sec}`.
      #
      # Soft-warn semantics (per the plan's R11): a persistent failure
      # does NOT hard-block the loop. After the cap, the runner writes
      # `reviews/browser-blocked-<pass>.md` and returns `:warned` so
      # `REVIEW_COMPLETE browser=warned` lands; 6-pr surfaces the
      # warning in the PR body. Browser flakiness is common; the user
      # decides whether to ship anyway.
      module BrowserTest
        Result = Data.define(:status, :attempts, :summary, :details, :error_message)

        DEFAULT_MAX_ATTEMPTS = 2

        module_function

        def run!(cfg:, ctx:)
          enabled = cfg.dig("review", "browser_test", "enabled")
          unless enabled
            return Result.new(
              status: :skipped,
              attempts: 0,
              summary: nil,
              details: nil,
              error_message: nil
            )
          end

          max_attempts = cfg.dig("review", "browser_test", "max_attempts") || DEFAULT_MAX_ATTEMPTS

          last_result = nil
          attempts = 0
          attempts_data = []

          (1..max_attempts).each do |attempt|
            attempts = attempt
            attempt_result = run_attempt(cfg: cfg, ctx: ctx, attempt: attempt)
            attempts_data << attempt_result
            last_result = attempt_result

            return Result.new(
              status: :passed,
              attempts: attempts,
              summary: attempt_result[:summary],
              details: attempt_result[:details],
              error_message: nil
            ) if attempt_result[:status] == :passed
          end

          # Cap reached without :passed — write the blocked finding file
          # so the U9 runner can surface it in the PR body when it
          # writes REVIEW_COMPLETE browser=warned.
          blocked_path = browser_blocked_path(ctx)
          FileUtils.mkdir_p(File.dirname(blocked_path))
          File.write(blocked_path, render_blocked_md(ctx, attempts_data))

          Result.new(
            status: :warned,
            attempts: attempts,
            summary: last_result&.dig(:summary),
            details: last_result&.dig(:details),
            error_message: nil
          )
        end

        # Run one browser-test attempt. Returns a hash with:
        #   status:   :passed | :failed
        #   summary:  String
        #   details:  String
        #   duration_sec: Numeric
        #   error_message: when status is :failed and the failure was a
        #                  spawn / parse failure (vs a real test failure)
        def run_attempt(cfg:, ctx:, attempt:)
          result_path = browser_result_path(ctx, attempt)
          FileUtils.mkdir_p(File.dirname(result_path))
          File.delete(result_path) if File.exist?(result_path)

          profile_name = cfg.dig("review", "browser_test", "agent") || "claude"
          profile = Hive::AgentProfiles.lookup(profile_name, cfg: cfg)
          template = cfg.dig("review", "browser_test", "prompt_template") || "browser_test_prompt.md.erb"
          template_path = Hive::Stages::Base.resolve_template_path(
            template,
            hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
          )

          prompt = Hive::Stages::Base.render_resolved_path(
            template_path,
            Hive::Stages::Base::TemplateBindings.new(
              project_name: File.basename(ctx.worktree_path),
              worktree_path: ctx.worktree_path,
              task_folder: ctx.task_folder,
              attempt: attempt,
              pass: ctx.pass,
              result_path: result_path,
              skill_invocation: format(profile.skill_syntax_format, skill: "ce-test-browser"),
              user_supplied_tag: Hive::Stages::Base.user_supplied_tag
            )
          )

          spawn_result = Hive::Stages::Base.spawn_agent(
            synthetic_task(ctx),
            prompt: prompt,
            add_dirs: [ ctx.task_folder ],
            cwd: ctx.worktree_path,
            max_budget_usd: cfg.dig("budget_usd", "review_browser") || 25,
            timeout_sec: cfg.dig("timeout_sec", "review_browser") || 900,
            log_label: "review-browser-pass#{format('%02d', ctx.pass)}-attempt#{format('%02d', attempt)}",
            profile: profile,
            expected_output: result_path,
            status_mode: :output_file_exists
          )

          if spawn_result[:status] != :ok
            return {
              status: :failed,
              summary: "agent spawn failed",
              details: spawn_result[:error_message].to_s,
              duration_sec: nil,
              error_message: spawn_result[:error_message]
            }
          end

          parse_result_file(result_path)
        end

        # Read the JSON result file the agent wrote. Tolerates malformed
        # / partial files by treating them as :failed with an explanatory
        # summary — the runner moves to the next attempt either way.
        def parse_result_file(path)
          unless File.exist?(path) && File.size(path) > 0
            return {
              status: :failed,
              summary: "browser test produced no result file",
              details: "expected #{path}; agent did not write it",
              duration_sec: nil,
              error_message: nil
            }
          end

          raw = File.read(path)
          parsed =
            begin
              JSON.parse(raw)
            rescue JSON::ParserError, TypeError => e
              # TypeError fires when the input isn't a String at all
              # (very rare from File.read, but `parsed["status"]` below
              # would TypeError if `parsed` is something other than Hash
              # — covered separately below).
              return {
                status: :failed,
                summary: "browser test produced unparseable JSON",
                details: "JSON parse error: #{e.message}\nRaw content (first 500 chars):\n#{raw[0, 500]}",
                duration_sec: nil,
                error_message: nil
              }
            end

          # Valid JSON whose root is an Array / String / Integer would
          # crash `parsed["status"]` with TypeError mid-Phase-5. Treat
          # any non-Hash root as a malformed-result :failed so the
          # runner can move to the next attempt.
          unless parsed.is_a?(Hash)
            return {
              status: :failed,
              summary: "browser test produced malformed JSON (non-hash root)",
              details: "non-hash JSON: #{parsed.class}\nRaw content (first 500 chars):\n#{raw[0, 500]}",
              duration_sec: nil,
              error_message: nil
            }
          end

          status_str = parsed["status"].to_s
          if status_str == "passed"
            {
              status: :passed,
              summary: parsed["summary"].to_s,
              details: parsed["details"].to_s,
              duration_sec: parsed["duration_sec"],
              error_message: nil
            }
          else
            # Preserve the raw status_str in details so the user sees
            # WHAT the agent reported (e.g. "skipped", "errored", "")
            # instead of a flat ":failed" with no clue.
            details = parsed["details"].to_s
            details = "agent reported status=#{status_str.inspect}#{details.empty? ? '' : "\n#{details}"}"
            {
              status: :failed,
              summary: parsed["summary"].to_s,
              details: details,
              duration_sec: parsed["duration_sec"],
              error_message: nil
            }
          end
        end

        def browser_result_path(ctx, attempt)
          File.join(
            ctx.task_folder,
            "reviews",
            "browser-result-#{format('%02d', ctx.pass)}-#{format('%02d', attempt)}.json"
          )
        end

        def browser_blocked_path(ctx)
          File.join(
            ctx.task_folder,
            "reviews",
            "browser-blocked-#{format('%02d', ctx.pass)}.md"
          )
        end

        # The blocked-finding file embeds every attempt's summary +
        # details so the user (or 6-pr's PR body) sees the full
        # progression, not just the last attempt.
        def render_blocked_md(ctx, attempts_data)
          out = +"# Browser test blocked for pass #{format('%02d', ctx.pass)}\n\n"
          out << "All #{attempts_data.size} attempts failed; loop continued with `browser=warned`.\n\n"
          attempts_data.each_with_index do |result, idx|
            out << "## Attempt #{idx + 1}\n\n"
            out << "**Summary:** #{result[:summary] || '(no summary)'}\n\n"
            duration = result[:duration_sec]
            out << "**Duration:** #{duration}s\n\n" if duration
            details = result[:details].to_s
            out << "**Details:**\n\n"
            out << if details.empty?
                     "_(no details)_\n\n"
            else
                     "```\n#{details}\n```\n\n"
            end
          end
          out
        end

        def synthetic_task(ctx)
          Hive::Reviewers.synthetic_task_for(ctx)
        end
      end
    end
  end
end
