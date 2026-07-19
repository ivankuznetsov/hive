require "json"
require "fileutils"
require "time"
require "hive"
require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/runner_task"
require "hive/patrol/token_budget"
require "hive/patrol/agent_launch"
require "hive/permission_scope"
require "hive/stages/base"

module Hive
  module RefactorPatrol
    # The production agent_runner for Reviewer: spawns the configured review
    # agent for one feature and records its usage. Reviewer only depends on
    # the call(feature:, prompt:, output_path:, run_dir:) protocol, so tests
    # and future runners can swap this out without touching orchestration.
    class ReviewAgentRunner
      STAGE = "refactor-patrol-review".freeze
      RAW_FINAL_MESSAGE_BASENAME = "final-message.txt".freeze

      def initialize(project_root:, cfg:, state:, dry_run: false, read_only: false,
                     token_budget: nil)
        @project_root = project_root
        @cfg = cfg
        @state = state
        @dry_run = dry_run
        @read_only = read_only
        @token_budget = token_budget || Hive::Patrol::TokenBudget.new(@project_root, cfg: cfg)
      end

      def call(prompt:, output_path:, run_dir:, timeout_sec: nil, **)
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
        scope = read_only_scope(profile)
        launch = Hive::Patrol::AgentLaunch.prepare(profile: profile, prompt: prompt, role: :review)
        unless @token_budget.acquire(stage: STAGE, minimum_tokens: launch.fetch(:minimum_tokens))
          exhaustion = @token_budget.resource_exhaustion if @token_budget.respond_to?(:resource_exhaustion)
          return {
            status: :error,
            error_message: @token_budget.exhaustion_message,
            resource_exhaustion: exhaustion
          }
        end
        started_at = Time.now.utc
        result = nil
        begin
          result = Hive::Agent.new(
            task: task,
            prompt: prompt,
            add_dirs: [ @project_root ],
            cwd: @project_root,
            max_budget_usd: @token_budget.max_budget_usd(
              @cfg.dig("budget_usd", "patrol") || 100, stage: STAGE
            ),
            max_tokens: @token_budget.max_tokens(stage: STAGE),
            max_turns: launch.fetch(:max_turns),
            timeout_sec: effective_timeout(timeout_sec),
            log_label: STAGE,
            profile: profile,
            expected_output: @read_only ? nil : output_path,
            status_mode: @read_only ? :exit_code_only : :output_file_exists,
            cli_flags: launch.fetch(:cli_flags),
            **scope
          ).run!
          if @read_only && resource_limited_with_final_message?(result)
            result = result.merge(status: :ok)
          end
          result = materialize_read_only_output(result, output_path) if @read_only
        ensure
          @token_budget.record!(
            result: result, profile: profile, stage: STAGE, started_at: started_at
          )
        end
        result
      end

      private

      def effective_timeout(remaining_run_seconds)
        configured = @cfg.dig("timeout_sec", "patrol") || 3600
        return configured if remaining_run_seconds.nil?

        [ configured, Float(remaining_run_seconds) ].min
      end

      def read_only_scope(profile)
        return {} unless @read_only
        unless profile.name == :claude
          raise Hive::ConfigError,
                "refactor patrol provider #{profile.name.inspect} cannot enforce read-only discovery; " \
                "configure refactor_patrol.agent: claude"
        end

        scope = Hive::PermissionScope.resolve(
          "read-only",
          task_folder: @project_root,
          profile: profile,
          stage: STAGE
        )
        Hive::Stages::Base.tool_scope_kwargs(scope.to_h)
      end

      def materialize_read_only_output(result, output_path)
        return result unless result.is_a?(Hash)

        raw = result[:final_message].to_s
        persist_raw_final_message(raw, output_path) if result.key?(:final_message)
        return result unless result[:status] == :ok

        doc = JSON.parse(read_only_json_body(raw))
        unless doc.is_a?(Hash) && doc["theses"].is_a?(Array)
          raise JSON::ParserError, "read-only review final message must be an object with a theses array"
        end
        File.write(output_path, "#{JSON.generate(doc)}\n")
        result
      rescue JSON::ParserError => e
        result.merge(status: :error, error_message: "invalid read-only review output: #{e.message}")
      end

      def persist_raw_final_message(raw, output_path)
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(File.join(File.dirname(output_path), RAW_FINAL_MESSAGE_BASENAME), raw)
      end

      # Claude occasionally wraps an otherwise exact JSON response in one
      # Markdown JSON fence. Accept only that whole-message wrapper; prose plus
      # embedded JSON remains invalid so the discovery contract stays strict.
      def read_only_json_body(raw)
        stripped = raw.to_s.strip
        match = /\A```(?:json)?[ \t]*\r?\n(?<body>.*)\r?\n```[ \t]*\z/im.match(stripped)
        match ? match[:body] : stripped
      end

      def resource_limited_with_final_message?(result)
        result.is_a?(Hash) &&
          %w[token_limit turn_limit].include?(result.dig(:resource_exhaustion, :reason)) &&
          !result[:final_message].to_s.strip.empty?
      end

      # Kept as the runner's narrow recording seam for tests and adapters;
      # TokenBudget owns the shared accounting semantics.
      def record_usage(result, profile, started_at)
        @token_budget.record!(
          result: result, profile: profile, stage: STAGE, started_at: started_at
        )
      end

      def configured_agent
        (@cfg.dig("refactor_patrol", "agent") || "claude").to_s
      end
    end
  end
end
