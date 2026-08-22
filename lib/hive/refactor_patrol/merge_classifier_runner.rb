require "digest"
require "json"

require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/agent_launch"
require "hive/patrol/launch_budget"
require "hive/patrol/runner_task"
require "hive/refactor_patrol/agent_identity"
require "hive/refactor_patrol/state_store"
require "hive/stages/base"

module Hive
  module RefactorPatrol
    # Provider adapter for MergeClassifier. It has no discovery allowance:
    # the durable classification store owns retry admission and this runner
    # records only non-discovery token telemetry.
    class MergeClassifierRunner
      STAGE = "refactor-patrol-merge-classifier".freeze
      class Error < Hive::Error
        attr_reader :retry_at

        def initialize(message, retry_at: nil)
          @retry_at = retry_at
          super(message)
        end
      end

      def initialize(project_root:, cfg:, state: nil, launch_budget: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state || StateStore.new(@project_root)
        @identity = AgentIdentity.new(cfg: cfg, project_root: @project_root).review
        @launch_budget = launch_budget || Hive::Patrol::LaunchBudget.new(
          @project_root, cfg: cfg, charge_discovery: false
        )
      end

      def call(prompt)
        run_dir = @state.run_dir("merge-classifier")
        task = Hive::Patrol::RunnerTask.new(
          folder: run_dir, project_root: @project_root,
          state_file: File.join(run_dir, "classifier.md"),
          log_dir: File.join(@state.root, "logs"), slug: STAGE
        )
        profile = Hive::AgentProfiles.lookup(@identity.provider, cfg: @cfg)
        launch = Hive::Patrol::AgentLaunch.prepare(profile: profile, role: :review)
        started_at = Time.now.utc
        unless @launch_budget.acquire(profile: profile, stage: STAGE, started_at: started_at)
          raise Error, @launch_budget.exhaustion_message
        end
        result = nil
        begin
          result = Hive::Agent.new(
            task: task, prompt: prompt, add_dirs: [], cwd: @project_root,
            max_budget_usd: nil, max_turns: launch.fetch(:max_turns),
            timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
            log_label: STAGE, profile: profile, expected_output: nil,
            status_mode: :exit_code_only, cli_flags: launch.fetch(:cli_flags),
            **Hive::Stages::Base.implementation_launch_arguments(@identity, profile)
          ).run!
        ensure
          @launch_budget.record!(
            result: result, profile: profile, stage: STAGE, started_at: started_at
          )
        end
        unless result.is_a?(Hash) && result[:status] == :ok
          exhaustion = result.is_a?(Hash) ? result[:resource_exhaustion] : nil
          detail = exhaustion.is_a?(Hash) ? " (#{exhaustion[:reason] || exhaustion['reason']})" : ""
          retry_at = if result.is_a?(Hash)
            result[:retry_at] || exhaustion&.[](:retry_at) || exhaustion&.[]("retry_at")
          end
          raise Error.new("merge classifier provider failed#{detail}", retry_at: retry_at)
        end

        value = JSON.parse(result.fetch(:final_message).to_s)
        keys = %w[decision evidence rationale]
        unless value.is_a?(Hash) && value.keys.sort == keys &&
               %w[feature skip].include?(value["decision"])
          raise Error, "merge classifier returned malformed JSON"
        end
        value.merge("model_receipt" => model_receipt(result))
      rescue JSON::ParserError, KeyError => error
        raise Error, "merge classifier returned malformed JSON: #{error.message}"
      end

      private

      def model_receipt(result)
        usage = result[:usage].is_a?(Hash) ? result[:usage] : {}
        model = result[:model] || usage[:model] || @identity.model || "unknown"
        digest = Digest::SHA256.hexdigest(JSON.generate(
          "model" => model.to_s,
          "session" => result[:session_id].to_s,
          "usage" => usage.transform_keys(&:to_s).sort.to_h
        ))
        "provider:#{model}:#{digest[0, 32]}"
      end
    end
  end
end
