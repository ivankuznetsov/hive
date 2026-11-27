require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/dependencies"
require "hive/model_routing"
require "hive/plan_dependency_adoption"
require "hive/plan_dependency_correction"
require "hive/plan_frontmatter"
require "hive/plan_review/execute_blocked"
require "hive/plan_review/identity"
require "hive/plan_review/orchestrator"
require "hive/plan_review/planner_identity"
require "hive/plan_review/policy"
require "hive/plan_review/projection"
require "hive/plan_review/store"
require "hive/stages/base"
require "hive/task_meta"
require "hive/workflows"

module Hive
  module PlanReview
    # Authoritative plan -> execute boundary. Review work happens in prepare!
    # before the caller takes the global commit lock; verify! then compares the
    # exact observation under the task lock immediately before folder mutation.
    module TransitionGuard
      PLAN_STAGE = "3-plan".freeze # coding-scoped: plan review only gates the coding plan stage
      EXECUTE_STAGE = "4-execute".freeze # coding-scoped: plan review only gates the coding execute hop
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
        return nil unless review_enabled?(cfg)

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

      # Interactive approval paths may validate an already-produced projection,
      # but must leave provider dispatch to plan-stage automation.
      def prepare_existing!(task:, destination:, config: nil)
        return nil unless transition_applicable?(task, destination)

        cfg = config || Hive::Config.load(task.project_root)
        return nil unless review_enabled?(cfg)

        projection = Projection.load(task_folder: task.folder)
        authorize!(task, projection, cfg:)
        observation(projection)
      rescue InvalidPlan, InvalidRecord, StaleObservation, Hive::ConfigError => error
        raise blocked_error(
          task, nil, "plan review evidence is unavailable or invalid: #{error.message}",
          required_action: "run or repair the plan review and retry"
        )
      end

      def verify!(task:, destination:, observation:, config: nil)
        return true unless transition_applicable?(task, destination)

        cfg = config || Hive::Config.load(task.project_root)
        return true unless review_enabled?(cfg)
        raise blocked_error(task, nil, "plan review observation is missing") unless observation

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
      def validate_execute_entry!(task:, config: nil, clock: -> { Time.now.utc },
                                  reviewed_rework: false)
        return true unless execute_applicable?(task)

        cfg = config || Hive::Config.load(task.project_root)
        return true unless review_enabled?(cfg)

        root = File.join(task.folder, Store::ROOT_BASENAME)
        unless File.exist?(root) || File.symlink?(root)
          if Hive::TaskMeta.plan_review_required?(task.folder)
            raise blocked_error(
              task, nil, "required plan review evidence is missing",
              required_action: "move the task back to plan and rerun its review"
            )
          end
          write_legacy_adoption!(task, clock:)
          return true
        end
        return true if legacy_adoption_valid?(task, root)

        authorize!(
          task, Projection.load(task_folder: task.folder), cfg:,
          allow_policy_drift: reviewed_rework
        )
        true
      rescue InvalidRecord, StaleObservation, Hive::ConfigError,
             Hive::TaskMeta::InvalidMetadata => error
        raise blocked_error(
          task, nil, "execute entry has invalid plan review evidence: #{error.message}",
          required_action: "move the task back to plan and repair its review"
        )
      end

      # A backward move into execute (for example 6-review -> 4-execute)
      # re-enters the execute boundary without crossing plan -> execute, so
      # nothing checked the review before the move. Preflight the evidence
      # execute entry will check and refuse a blocked review at the move, with
      # the remedy, instead of letting execute entry refuse every dispatch.
      # Read-only: unlike validate_execute_entry! it never records a legacy
      # adoption receipt. Policy drift alone is tolerated because an
      # outcome-evidence rework may keep its reviewed clearance; execute entry
      # remains the authority for that and for anything that changes later.
      def validate_execute_reentry!(task:, destination:, config: nil)
        return true unless reentry_applicable?(task, destination)

        cfg = config || Hive::Config.load(task.project_root)
        return true unless review_enabled?(cfg)

        root = File.join(task.folder, Store::ROOT_BASENAME)
        unless File.exist?(root) || File.symlink?(root)
          return true unless Hive::TaskMeta.plan_review_required?(task.folder)

          raise blocked_error(task, nil, "required plan review evidence is missing")
        end
        return true if legacy_adoption_valid?(task, root)

        authorize!(
          task, Projection.load(task_folder: task.folder), cfg:, allow_policy_drift: true
        )
        true
      rescue InvalidRecord, StaleObservation, Hive::ConfigError,
             Hive::TaskMeta::InvalidMetadata => error
        raise reentry_blocked(
          task, blocked_error(task, nil, "execute re-entry has invalid plan review evidence: #{error.message}")
        )
      rescue TransitionBlocked => error
        raise reentry_blocked(task, error)
      end

      def transition_applicable?(task, destination)
        coding?(task) && stage_dir(task) == PLAN_STAGE && destination.to_s == EXECUTE_STAGE
      end

      def execute_applicable?(task)
        coding?(task) && stage_dir(task) == EXECUTE_STAGE
      end

      def review_enabled?(cfg)
        cfg.dig("plan_review", "enabled") != false
      end

      def authorize!(task, projection, cfg:, allow_policy_drift: false)
        unless projection.is_a?(Projection)
          raise blocked_error(
            task, nil, "plan review has not produced a current resolution",
            required_action: "run the plan review"
          )
        end

        record = projection.record
        current_freshness = freshness(
          task:, projection:, config: cfg, allow_policy_drift:
        )
        fresh = current_freshness.fetch("status") == "current"
        executable = record.execution_allowed? && record["blockers"].empty?
        if fresh && executable
          validate_current_dependencies!(task, projection)
          return projection
        end

        reason = current_freshness["reason"] ||
          "plan review is #{record.state} and does not authorize execution"
        raise blocked_error(task, projection, reason)
      end

      # Review task_generation intentionally excludes `depends_on` so
      # permitted adoption preserves review identity. Therefore freshness alone
      # cannot prove that current plan.md and meta.yml still agree and resolve
      # at dispatch/approve/execute entry.
      def validate_current_dependencies!(task, projection)
        meta = Hive::TaskMeta.read_for_admission(task.folder)
        unless meta.ok?
          raise blocked_error(
            task, projection,
            "task dependency metadata is invalid or unreadable (#{meta.reason})",
            required_action: "repair #{task.folder}/meta.yml and retry"
          )
        end

        plan_path = File.join(task.folder, "plan.md")
        plan_read = Hive::PlanFrontmatter.read(plan_path)
        if plan_read.status == :invalid
          raise blocked_error(
            task, projection,
            "plan.md depends_on frontmatter is invalid (#{plan_read.error || plan_read.invalid_kind})",
            required_action: Hive::PlanDependencyCorrection.exhausted_action(task: task, validation: nil)
          )
        end
        return unless plan_read.has_depends_on?

        plan_normalized = Hive::Dependencies.serialize_declaration(plan_read.depends_on)
        meta_raw = meta.data[:depends_on]
        if meta_raw.nil?
          raise blocked_error(
            task, projection,
            "plan.md depends_on is not recorded in meta.yml (plan_dependency_missing)",
            required_action: "align meta.yml and plan.md depends_on and retry"
          )
        end
        meta_normalized = Hive::Dependencies.normalize_declaration(meta_raw)
        unless plan_normalized == meta_normalized
          raise blocked_error(
            task, projection,
            "plan.md depends_on disagrees with meta.yml (plan_dependency_mismatch)",
            required_action: "align meta.yml and plan.md depends_on and retry"
          )
        end

        return unless task.respond_to?(:project_root) && task.project_root &&
                      project_registered?(task.project_root)

        validation = Hive::PlanDependencyAdoption.validate(task)
        return if validation.ok? && !validation.adoptable?

        raise blocked_error(
          task, projection,
          "plan dependencies failed validation (#{validation.reason_code || 'plan_dependency_missing'}: #{validation.offending_ref})",
          required_action: validation.safe_correction ||
                           Hive::PlanDependencyCorrection.exhausted_action(task: task, validation: validation)
        )
      rescue Hive::Dependencies::InvalidReference => error
        raise blocked_error(
          task, projection,
          "plan dependency metadata is invalid: #{error.message}",
          required_action: "repair depends_on in #{task.folder}/meta.yml and plan.md"
        )
      end

      def project_registered?(project_root)
        expanded = File.expand_path(project_root.to_s)
        Hive::Config.registered_projects.any? do |entry|
          File.expand_path(entry.fetch("path")) == expanded
        end
      rescue StandardError
        false
      end

      def freshness(task:, projection:, config:, allow_policy_drift: false)
        record = projection.record
        required_digest = record["candidate_plan_digest"] || record.plan_digest
        allowed_digests = record.execution_allowed? ? [ required_digest ] : [ record.plan_digest, required_digest ]
        return stale("task generation changed after plan review") unless
          Identity.task_generation_current?(task, record.task_generation)
        return stale("canonical plan changed after plan review") unless
          allowed_digests.include?(current_plan_digest(task))
        unless allow_policy_drift || policy_configuration_matches?(record, task, config)
          return stale("plan review policy changed after resolution")
        end

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
        return false unless artifact.is_a?(Hash)

        run_level = persisted_run_level(store)
        Policy.configuration_current?(cfg, artifact:, record:) &&
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
        Hive::PlanReview::PlannerIdentity.capture(
          profile:, cfg:, reconstructed: true
        )
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

      def legacy_adoption_valid?(task, root)
        return false if Hive::TaskMeta.plan_review_required?(task.folder)

        path = File.join(root, "legacy-execute-adoption.json")
        return false unless File.file?(path) && !File.symlink?(path)

        bytes = File.binread(path, Store::MAX_JSON_BYTES + 1)
        raise InvalidRecord, "legacy execute adoption exceeds the size limit" if
          bytes.bytesize > Store::MAX_JSON_BYTES
        receipt = JSON.parse(bytes)
        receipt["schema"] == ADOPTION_SCHEMA && receipt["schema_version"] == 1 &&
          receipt["task_id"] == (task.id || task.slug).to_s &&
          Identity.task_generation_current?(task, receipt["task_generation"]) &&
          receipt["stage"] == EXECUTE_STAGE &&
          receipt["reason"] == "pre_feature_execute_task"
      rescue JSON::ParserError
        raise InvalidRecord, "legacy execute adoption is invalid JSON"
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
          blocked_reason: reason,
          current_stage: stage_dir(task), target_stage: EXECUTE_STAGE
        )
      end

      def coding?(task)
        task.respond_to?(:workflow) && Hive::Workflows.coding_id?(task.workflow.id)
      end

      # Only a move from a stage after execute re-enters it; plan -> execute
      # is prepare!/verify!'s boundary.
      def reentry_applicable?(task, destination)
        coding?(task) && destination.to_s == EXECUTE_STAGE &&
          task.stage_index.to_i > EXECUTE_STAGE.to_i
      end

      # Re-entry refusals name the concrete remedy as the required action: the
      # review can only be restarted once the task is back at plan.
      def reentry_blocked(task, error)
        from_stage = stage_dir(task)
        remedy = ExecuteBlocked.remedy(
          slug: task.slug, from_stage:, blocked_reason: error.blocked_reason
        )
        TransitionBlocked.new(
          "#{error.blocked_reason}; required action: #{remedy}",
          review_id: error.review_id, review_state: error.review_state,
          required_action: remedy, blockers: error.blockers,
          blocked_reason: error.blocked_reason,
          current_stage: from_stage, target_stage: EXECUTE_STAGE
        )
      end

      def stage_dir(task) = "#{task.stage_index}-#{task.stage_name}"

      private_class_method :authorize!, :validate_current_dependencies!,
                           :project_registered?, :observation, :policy_configuration_matches?,
                           :current_plan_digest, :write_legacy_adoption!,
                           :persisted_run_level, :blocked_error,
                           :stale, :coding?, :stage_dir,
                           :reentry_applicable?, :reentry_blocked
    end
  end
end
