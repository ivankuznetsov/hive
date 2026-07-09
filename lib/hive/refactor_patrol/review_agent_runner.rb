require "time"
require "hive"
require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/runner_task"
require "hive/usage_db"

module Hive
  module RefactorPatrol
    # The production agent_runner for Reviewer: spawns the configured review
    # agent for one feature and records its usage. Reviewer only depends on
    # the call(feature:, prompt:, output_path:, run_dir:) protocol, so tests
    # and future runners can swap this out without touching orchestration.
    class ReviewAgentRunner
      STAGE = "refactor-patrol-review".freeze

      def initialize(project_root:, cfg:, state:, dry_run: false)
        @project_root = project_root
        @cfg = cfg
        @state = state
        @dry_run = dry_run
      end

      def call(prompt:, output_path:, run_dir:, **)
        task = Hive::Patrol::RunnerTask.new(
          folder: run_dir,
          project_root: @project_root,
          state_file: File.join(run_dir, "review.md"),
          # In dry-run mode the run_dir is a throwaway tmp dir; route agent
          # logs there too so a preview creates no durable artifacts under
          # .hive-state/refactor_patrol/.
          log_dir: @dry_run ? File.join(run_dir, "logs") : File.join(@state.root, "logs"),
          slug: STAGE
        )
        profile = Hive::AgentProfiles.lookup(configured_agent, cfg: @cfg)
        started_at = Time.now.utc
        result = Hive::Agent.new(
          task: task,
          prompt: prompt,
          add_dirs: [ @project_root ],
          cwd: @project_root,
          max_budget_usd: @cfg.dig("budget_usd", "patrol") || 100,
          timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
          log_label: STAGE,
          profile: profile,
          expected_output: output_path,
          status_mode: :output_file_exists
        ).run!
        record_usage(result, profile, started_at)
        result
      end

      private

      def record_usage(result, profile, started_at)
        usage = result && result[:usage]
        return unless usage

        Hive::UsageDb.record!(
          agent: profile_name(profile),
          model: usage[:model] || result[:model],
          project_slug: File.basename(@project_root.to_s),
          task_slug: STAGE,
          stage: STAGE,
          started_at: started_at,
          ended_at: Time.now.utc.iso8601,
          input: usage[:input] || 0,
          output: usage[:output] || 0,
          cached: usage[:cached] || 0
        )
      rescue StandardError => e
        warn "[hive] usage record failed: #{e.message}"
      end

      def profile_name(profile)
        return profile.name.to_s if profile.respond_to?(:name)

        configured_agent
      end

      def configured_agent
        (@cfg.dig("refactor_patrol", "agent") || "claude").to_s
      end
    end
  end
end
