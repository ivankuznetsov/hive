require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/model_routing"
require "hive/plan_review/identity"
require "hive/plan_review/orchestrator"
require "hive/plan_review/policy"
require "hive/plan_review/projection"
require "hive/plan_review/store"
require "hive/stages/base"
require "hive/workflows"

module Hive
  module PlanReview
    # Authoritative plan -> execute boundary. Review work happens in prepare!
    # before the caller takes the global commit lock; verify! then compares the
    # exact observation under the task lock immediately before folder mutation.
    module TransitionGuard
      PLAN_STAGE = "3-plan".freeze
      EXECUTE_STAGE = "4-execute".freeze
      ADOPTION_SCHEMA = "hive-plan-review-adoption".freeze

      Observation = Data.define(
        :review_id, :version, :observation_digest, :task_generation,
        :plan_digest, :policy_fingerprint
      )

      module_function

      def prepare!(task:, destination:, config: nil, orchestrator: nil,
                   planner_identity: nil)
        return nil unless transition_applicable?(task, destination)

        cfg = config || Hive::Config.load(task.project_root)
        projection = if orchestrator
          orchestrator.call(task:, cfg:, planner_identity: planner_identity || {})
        else
          Orchestrator.run!(
            task:, cfg:,
            planner_identity: planner_identity || reconstructed_planner_identity(cfg)
          )
        end
        authorize!(task, projection, cfg:)
        observation(projection)
      rescue InvalidPlan, InvalidRecord, StaleObservation, Hive::ConfigError => error
        raise blocked_error(
          task, nil, "plan review evidence is unavailable or invalid: #{error.message}",
          required_action: "repair plan review evidence and retry"
        )
      end

      def verify!(task:, destination:, observation:, config: nil)
        return true unless transition_applicable?(task, destination)
        raise blocked_error(task, nil, "plan review observation is missing") unless observation

        cfg = config || Hive::Config.load(task.project_root)
        projection = Projection.load(task_folder: task.folder)
        authorize!(task, projection, cfg:)
        actual = self.observation(projection)
        unless actual == observation
          raise blocked_error(
            task, projection, "plan review changed before the transition",
            required_action: "refresh plan review state and retry"
          )
        end
        true
      rescue InvalidRecord, StaleObservation, Hive::ConfigError => error
        raise blocked_error(
          task, nil, "plan review evidence changed or is invalid: #{error.message}",
          required_action: "refresh plan review state and retry"
        )
      end

      # Execute-stage entry is a backstop for manual/raw folder movement. A
      # task carrying review state must prove current clearance. A task with no
      # review root is treated as an explicitly receipted pre-feature task so
      # upgrades do not retroactively strand work already in execute.
      def validate_execute_entry!(task:, config: nil, clock: -> { Time.now.utc })
        return true unless execute_applicable?(task)

        root = File.join(task.folder, Store::ROOT_BASENAME)
        unless File.exist?(root) || File.symlink?(root)
          write_legacy_adoption!(task, clock:)
          return true
        end

        cfg = config || Hive::Config.load(task.project_root)
        authorize!(task, Projection.load(task_folder: task.folder), cfg:)
        true
      rescue InvalidRecord, StaleObservation, Hive::ConfigError => error
        raise blocked_error(
          task, nil, "execute entry has invalid plan review evidence: #{error.message}",
          required_action: "move the task back to plan and repair its review"
        )
      end

      def transition_applicable?(task, destination)
        coding?(task) && stage_dir(task) == PLAN_STAGE && destination.to_s == EXECUTE_STAGE
      end

      def execute_applicable?(task)
        coding?(task) && stage_dir(task) == EXECUTE_STAGE
      end

      def authorize!(task, projection, cfg:)
        unless projection.is_a?(Projection)
          raise blocked_error(
            task, nil, "plan review has not produced a current resolution",
            required_action: "run the plan review"
          )
        end

        record = projection.record
        current_freshness = freshness(task:, projection:, config: cfg)
        fresh = current_freshness.fetch("status") == "current"
        executable = record.execution_allowed? && record["blockers"].empty?
        return projection if fresh && executable

        reason = current_freshness["reason"] ||
          "plan review is #{record.state} and does not authorize execution"
        raise blocked_error(task, projection, reason)
      end

      def freshness(task:, projection:, config:)
        record = projection.record
        allowed_digests = [ record.plan_digest, record["candidate_plan_digest"] ].compact
        return stale("task generation changed after plan review") unless
          record.task_generation.to_s == Identity.task_generation(task).to_s
        return stale("canonical plan changed after plan review") unless
          allowed_digests.include?(current_plan_digest(task))
        return stale("plan review policy changed after resolution") unless
          policy_configuration_matches?(record, task, config)

        { "status" => "current", "reason" => nil }.freeze
      rescue InvalidPlan, InvalidRecord, SystemCallError, IOError => error
        { "status" => "invalid", "reason" => error.message }.freeze
      end

      def observation(projection)
        record = projection.record
        Observation.new(
          review_id: record.review_id, version: record.version,
          observation_digest: projection.observation_digest,
          task_generation: record.task_generation,
          plan_digest: record["candidate_plan_digest"] || record.plan_digest,
          policy_fingerprint: record.policy_fingerprint
        ).freeze
      end

      def policy_configuration_matches?(record, task, cfg)
        store = Store.new(task_folder: task.folder)
        reference = record["artifacts"]["policy"]
        return false unless reference

        artifact = JSON.parse(store.read_reference(reference))
        run_level = persisted_run_level(store)
        artifact["configuration_fingerprint"] == Policy.configuration_fingerprint(cfg) &&
          record["level_sources"]&.dig("run") == run_level
      rescue JSON::ParserError, KeyError, TypeError
        false
      end

      def current_plan_digest(task)
        path = File.join(task.folder, "plan.md")
        stat = File.lstat(path)
        raise InvalidPlan, "plan.md must be a regular file" if stat.symlink? || !stat.file?

        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError, IOError => error
        raise InvalidPlan, "plan.md is unavailable: #{error.message}"
      end

      def reconstructed_planner_identity(cfg)
        profile = Hive::Stages::Base.stage_profile(cfg, "plan")
        routing = Hive::ModelRouting.resolve(
          models: cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: "plan", provider: profile.name,
          current: Hive::Stages::Base.model_routing_current(cfg["plan"]),
          legacy: Hive::Stages::Base.model_routing_current(cfg["claude"])
        )
        {
          "provider" => profile.name.to_s,
          "model" => (routing.model || cfg.dig("plan", "model") || "unknown").to_s,
          "family" => planner_family(profile.name),
          "effort" => (routing.effort || cfg.dig("plan", "effort") ||
            cfg.dig("claude", "effort") || "unknown").to_s,
          "route" => profile.launcher_identity.to_s,
          "reconstructed" => true
        }.freeze
      end

      def write_legacy_adoption!(task, clock:)
        root = File.join(task.folder, Store::ROOT_BASENAME)
        FileUtils.mkdir_p(root, mode: 0o700)
        File.chmod(0o700, root)
        path = File.join(root, "legacy-execute-adoption.json")
        return true if File.file?(path) && !File.symlink?(path)

        receipt = {
          "schema" => ADOPTION_SCHEMA, "schema_version" => 1,
          "task_id" => (task.id || task.slug).to_s,
          "task_generation" => Identity.task_generation(task),
          "stage" => EXECUTE_STAGE, "reason" => "pre_feature_execute_task",
          "adopted_at" => clock.call.utc.iso8601(6)
        }
        Hive::AtomicFile.write(path, "#{JSON.generate(receipt)}\n", mode: 0o600)
        File.chmod(0o600, path)
        true
      rescue SystemCallError, IOError => error
        raise InvalidRecord, "legacy execute adoption could not be recorded: #{error.message}"
      end

      def persisted_run_level(store)
        path = File.join(store.root, "level.json")
        return nil unless File.file?(path) && !File.symlink?(path)

        JSON.parse(File.binread(path))["level"]
      rescue JSON::ParserError, SystemCallError, IOError
        nil
      end

      def stale(reason) = { "status" => "stale", "reason" => reason }.freeze

      def blocked_error(task, projection, reason, required_action: nil)
        record = projection&.record
        action = required_action || record&.required_action || "complete or resolve the plan review"
        TransitionBlocked.new(
          "#{reason}; required action: #{action}",
          review_id: record&.review_id, review_state: record&.state,
          required_action: action, blockers: record ? record["blockers"] : [],
          current_stage: stage_dir(task), target_stage: EXECUTE_STAGE
        )
      end

      def coding?(task)
        task.respond_to?(:workflow) && Hive::Workflows.coding_id?(task.workflow.id)
      end

      def stage_dir(task) = "#{task.stage_index}-#{task.stage_name}"

      def planner_family(name)
        { claude: "anthropic", codex: "openai", grok: "grok", pi: "pi" }
          .fetch(name.to_sym, "unknown")
      end

      private_class_method :authorize!, :observation, :policy_configuration_matches?,
                           :current_plan_digest, :write_legacy_adoption!,
                           :persisted_run_level, :blocked_error,
                           :stale, :coding?, :stage_dir, :planner_family
    end
  end
end
