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
      def run!
        ensure_reviews_dir!

        profile = Hive::AgentProfiles.lookup(spec.fetch("agent"))
        skill = spec.fetch("skill")
        prompt = render_prompt(profile, skill)

        result = Hive::Stages::Base.spawn_agent(
          synthetic_task,
          prompt: prompt,
          add_dirs: [ ctx.task_folder ],
          cwd: ctx.worktree_path,
          max_budget_usd: spec["budget_usd"] || 50,
          timeout_sec: spec["timeout_sec"] || 600,
          log_label: "review-#{name}-pass#{format('%02d', ctx.pass)}",
          profile: profile,
          expected_output: output_path,
          # Reviewer spawns own a per-pass output file, not the task
          # marker — the orchestrator's REVIEW_WORKING marker must
          # persist across each reviewer's spawn.
          status_mode: :output_file_exists
        )

        if result[:status] == :ok
          Result.new(
            name: name,
            output_path: output_path,
            status: :ok,
            error_message: nil
          )
        else
          Result.new(
            name: name,
            output_path: output_path,
            status: :error,
            error_message: result[:error_message] || "agent exited with status=#{result[:status]}"
          )
        end
      end

      private

      def render_prompt(profile, skill)
        Hive::Stages::Base.render(
          spec.fetch("prompt_template"),
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(ctx.worktree_path),
            worktree_path: ctx.worktree_path,
            task_folder: ctx.task_folder,
            default_branch: ctx.default_branch,
            pass: ctx.pass,
            output_path: output_path,
            skill_invocation: format(profile.skill_syntax_format, skill: skill),
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      # spawn_agent expects a task-shaped object with folder, state_file,
      # log_dir, and stage_name. The 5-review runner has the real Task
      # but the reviewer adapter receives a Context with paths only —
      # build a minimal facade. This is the only place state_file is
      # named; the agent never writes to it because :output_file_exists
      # mode bypasses task.state_file marker writes (see agent.rb mode
      # gating).
      def synthetic_task
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
