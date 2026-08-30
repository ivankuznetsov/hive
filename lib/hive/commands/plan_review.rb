require "json"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/plan_review/decision_service"
require "hive/plan_review/automation"
require "hive/plan_review/orchestrator"
require "hive/task"
require "hive/task_resolver"

module Hive
  module Commands
    class PlanReview
      include Hive::Schemas::EnvelopeEmitter

      SUCCESS_KEYS = %w[
        schema schema_version ok applied noop action decision_id target_fingerprint
        review_id current_review_id task_generation policy_fingerprint state outcome
        execution_allowed required_action observation_digest slug task_folder
      ].freeze

      def self.persist_raise_for_target!(target, level:, project: nil, stage: nil,
                                         operator: nil, reason: nil)
        task = Hive::TaskResolver.new(
          target, project_filter: project, stage_filter: stage
        ).resolve
        operator = normalized_operator(operator)
        result = nil
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          result = Hive::PlanReview::DecisionService.persist_raise!(
            task:, level:, operator:, reason:
          )
          if result.fetch("applied")
            Hive::GitOps.new(task.project_root).hive_commit(
              stage_name: "#{task.stage_index}-#{task.stage_name}", slug: task.slug,
              action: "raise plan review level to #{result.fetch('level')}"
            )
          end
        end
        result
      end

      def self.normalized_operator(value = nil)
        operator = value.to_s.strip
        operator = ENV["USER"].to_s.strip if operator.empty?
        operator.empty? ? "local-operator" : operator
      end

      def initialize(target, action, review_id:, task_generation:, policy_fingerprint:,
                     expected_artifact_digest:, target_fingerprint: nil, answer: nil,
                     coverage: nil, level: nil, reason: nil, project: nil,
                     json: false, operator: nil, resolver: nil,
                     service_factory: nil, resumer: nil)
        @target = target
        @action = action.to_s.tr("-", "_")
        @review_id = review_id
        @task_generation = task_generation
        @policy_fingerprint = policy_fingerprint
        @expected_artifact_digest = expected_artifact_digest
        @target_fingerprint = target_fingerprint
        @answer = answer
        @coverage = coverage
        @level = level
        @reason = reason
        @project = project
        @json = json
        @operator = self.class.normalized_operator(operator)
        @resolver = resolver || lambda do
          Hive::TaskResolver.new(@target, project_filter: @project).resolve
        end
        @service_factory = service_factory || ->(task) { Hive::PlanReview::DecisionService.new(task:) }
        @resumer = resumer || method(:resume_review!)
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = "hive-plan-review-action"

      def envelope_error_kind(error)
        case error
        when Hive::PlanReview::StaleDecision then "stale_decision"
        when Hive::PlanReview::ConflictingDecision then "conflicting_decision"
        when Hive::PlanReview::UnauthorizedAction then "unauthorized"
        when Hive::PlanReview::InvalidAction then "invalid_action"
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConcurrentRunError then "concurrent_run"
        when Hive::ConfigError then "config"
        when Hive::GitError then "git"
        when Hive::InternalError then "internal"
        else "error"
        end
      end

      def envelope_serialization_failure_policy = :raise

      private

      def do_call
        validate_observation_arguments!
        task = @resolver.call
        result = @service_factory.call(task).apply(
          action: @action, review_id: @review_id,
          task_generation: @task_generation,
          policy_fingerprint: @policy_fingerprint,
          expected_artifact_digest: @expected_artifact_digest,
          target_fingerprint: @target_fingerprint,
          value: Hive::PlanReview::DecisionService.action_value(
            @action, answer: @answer, coverage: @coverage, level: @level
          ),
          reason: @reason, origin: "cli", operator: @operator,
          # ADR-008's local same-user boundary treats an intentional direct CLI
          # invocation as operator authority. An agent granted unrestricted
          # shell access therefore has that user's authority too.
          authorized: true
        )
        projection = result.applied ? @resumer.call(task) : result.projection
        emit_success(task, result, projection)
      end

      def validate_observation_arguments!
        {
          "--review-id" => @review_id,
          "--task-generation" => @task_generation,
          "--policy-fingerprint" => @policy_fingerprint,
          "--expected-artifact-digest" => @expected_artifact_digest
        }.each do |flag, value|
          raise Hive::PlanReview::InvalidAction, "#{flag} is required" if value.to_s.strip.empty?
        end
      end

      def resume_review!(task)
        projection = nil
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "plan-review-resume") do
            locked = Hive::Task.new(task.folder)
            cfg = Hive::Config.load(locked.project_root)
            current = Hive::PlanReview::Projection.load(task_folder: locked.folder)
            identity = Hive::PlanReview::Automation.planner_identity_for(
              current.record, cfg
            )
            projection = Hive::PlanReview::Orchestrator.run!(
              task: locked, cfg:, planner_identity: identity
            )
          end
          Hive::GitOps.new(task.project_root).hive_commit(
            stage_name: "#{task.stage_index}-#{task.stage_name}", slug: task.slug,
            action: "resume plan review after #{@action}"
          )
        end
        projection
      end

      def emit_success(task, result, projection)
        payload = {
          "schema" => envelope_schema,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
          "ok" => true, "applied" => result.applied, "noop" => result.noop?,
          "action" => result.decision.action,
          "decision_id" => result.decision.decision_id,
          "target_fingerprint" => result.decision.target_fingerprint,
          "review_id" => result.decision["review_id"],
          "current_review_id" => projection.record.review_id,
          "task_generation" => projection.record.task_generation.to_s,
          "policy_fingerprint" => projection.record.policy_fingerprint,
          "state" => projection.record.state, "outcome" => projection.record.outcome,
          "execution_allowed" => projection.record.execution_allowed?,
          "required_action" => projection.record.required_action,
          "observation_digest" => projection.observation_digest,
          "slug" => task.slug, "task_folder" => task.folder
        }
        payload = SUCCESS_KEYS.to_h { |key| [ key, payload.fetch(key) ] }
        puts JSON.generate(payload) if @json
        unless @json
          verb = result.applied ? "applied" : "already applied"
          puts "hive: #{verb} plan review #{result.decision.action} for #{task.slug}"
          puts "  review: #{projection.record.review_id} #{projection.record.state}"
          puts "  required_action: #{projection.record.required_action}" if projection.record.required_action
        end
        payload
      end
    end
  end
end
