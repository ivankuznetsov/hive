require "json"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/plan_review/adapters/base"
require "hive/plan_review/decision"
require "hive/plan_review/projection"
require "hive/plan_review/store"
require "hive/plan_review/transition_guard"
require "hive/secret_patterns"
require "hive/task"

module Hive
  module PlanReview
    class DecisionService
      TRANSIENT_OUTCOMES = Adapters::Base::TRANSIENT_OUTCOMES
      RECOVERABLE_TERMINAL_OUTCOMES = (
        Adapters::Base::OUTCOMES - Adapters::Base::SUCCESS_OUTCOMES - TRANSIENT_OUTCOMES
      ).freeze
      RECOVERABLE_ROLES = %w[primary adversarial verification planner_revision].freeze

      Result = Data.define(:applied, :decision, :projection) do
        def noop? = !applied
      end

      def initialize(task:, clock: -> { Time.now.utc }, task_locker: nil,
                     commit_locker: nil, committer: nil, freshness_checker: nil)
        @task = task
        @clock = clock
        @store = Store.new(task_folder: task.folder)
        @task_locker = task_locker || lambda do |&block|
          Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "plan-review-decision", &block)
        end
        @commit_locker = commit_locker || lambda do |&block|
          Hive::Lock.with_commit_lock(task.hive_state_path, &block)
        end
        @committer = committer || method(:commit!)
        @freshness_checker = freshness_checker || method(:validate_current_freshness!)
      end

      def apply(action:, review_id:, task_generation:, policy_fingerprint:,
                expected_artifact_digest:, target_fingerprint: nil, value: nil,
                reason: nil, origin:, operator:, authorized: false)
        outcome = nil
        @commit_locker.call do
          @task_locker.call do
            current = @store.current
            @freshness_checker.call(current)
            target = normalize_target(action, target_fingerprint, value, review_id, current)
            decision = build_decision(
              action:, review_id:, task_generation:, policy_fingerprint:,
              expected_artifact_digest:, target_fingerprint: target, value:,
              reason:, origin:, operator:
            )
            authorize!(decision, authorized:)
            if (existing = current["decisions"].find do |entry|
              entry["decision_id"] == decision.decision_id
            end)
              outcome = Result.new(
                applied: false, decision: Decision.new(existing),
                projection: Projection.new(current)
              ).freeze
              next
            end
            conflicting = current["decisions"].find do |entry|
              entry["target_fingerprint"] == decision.target_fingerprint &&
                entry["decision_id"] != decision.decision_id
            end
            if conflicting
              raise ConflictingDecision,
                    "plan review target already has decision #{conflicting.fetch('decision_id')}"
            end
            validate_observation!(current, decision)
            updated = apply_to_record(current, decision)
            reference = @store.write_decision!(
              review_id: current.review_id,
              target_fingerprint: decision.target_fingerprint,
              decision_id: decision.decision_id,
              data: decision.to_h
            )
            updated["artifacts"] = updated.fetch("artifacts").merge(
              "decision_#{decision.decision_id}" => reference
            )
            updated["decisions"] = updated.fetch("decisions") + [ decision.to_h ]
            updated["version"] = current.version + 1
            updated["updated_at"] = timestamp
            projection = @store.publish_current!(
              Record.new(updated), expected_version: current.version
            )
            outcome = Result.new(
              applied: true, decision:, projection: Projection.new(projection)
            ).freeze
          end
          @committer.call(outcome.decision.action) if outcome&.applied
        end
        outcome
      rescue StaleObservation => e
        raise StaleDecision, e.message
      end

      def self.persist_raise!(task:, level:, operator:, reason: nil,
                              clock: -> { Time.now.utc })
        level = Hive::PlanReview.level!(level, label: "plan --review-level")
        unless %w[standard mandatory].include?(level)
          raise InvalidAction, "--review-level is raise-only and accepts standard or mandatory"
        end
        store = Store.new(task_folder: task.folder)
        path = File.join(store.root, "level.json")
        Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "plan-review-raise") do
          write_raise_receipt!(task:, path:, level:, operator:, reason:, clock:)
        end
      end

      def self.action_value(action, answer: nil, coverage: nil, level: nil)
        case action.to_s.tr("-", "_")
        when "answer_finding" then { "answer" => answer }
        when "waive_coverage" then { "coverage" => coverage }
        when "downgrade_level", "raise_level" then { "level" => level }
        else {}
        end
      end

      def self.read_level(path)
        return nil unless File.file?(path) && !File.symlink?(path)

        value = JSON.parse(File.binread(path))
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError, SystemCallError, IOError
        nil
      end
      private_class_method :read_level

      def self.write_raise_receipt!(task:, path:, level:, operator:, reason:, clock:)
        existing = read_level(path)
        if existing
          current = Hive::PlanReview.level!(existing.fetch("level"))
          if LEVEL_RANK.fetch(level) < LEVEL_RANK.fetch(current)
            raise InvalidAction, "review level cannot be lowered from #{current} to #{level}"
          end
          return { "applied" => false, "level" => current, "receipt" => existing } if current == level
        end
        receipt = {
          "schema" => "hive-plan-review-level", "schema_version" => 1,
          "task_id" => (task.id || task.slug).to_s, "level" => level,
          "operator" => operator.to_s, "reason" => Hive::SecretPatterns.redact(reason.to_s),
          "raised_at" => clock.call.utc.iso8601(6)
        }
        Hive::AtomicFile.write(path, "#{JSON.generate(receipt)}\n", mode: 0o600)
        File.chmod(0o600, path)
        { "applied" => true, "level" => level, "receipt" => receipt }
      end
      private_class_method :write_raise_receipt!

      private

      def build_decision(action:, review_id:, task_generation:, policy_fingerprint:,
                         expected_artifact_digest:, target_fingerprint:, value:,
                         reason:, origin:, operator:)
        normalized_value = normalize_value(action, value)
        Decision.new(
          "schema" => Decision::SCHEMA, "schema_version" => Decision::SCHEMA_VERSION,
          "review_id" => review_id, "task_generation" => task_generation,
          "policy_fingerprint" => policy_fingerprint,
          "expected_artifact_digest" => expected_artifact_digest,
          "target_fingerprint" => target_fingerprint, "action" => action.to_s,
          "value" => normalized_value,
          "reason" => reason && Hive::SecretPatterns.redact(reason.to_s),
          "origin" => origin.to_s, "operator" => operator.to_s,
          "policy_receipt" => nil, "decided_at" => timestamp
        )
      end

      def normalize_value(action, value)
        case action.to_s
        when "approve_finding", "retry", "request_review"
          {}
        when "answer_finding"
          answer = value.is_a?(Hash) ? value["answer"] || value[:answer] : value
          raise InvalidAction, "answer_finding requires a non-empty answer" if answer.to_s.strip.empty?

          { "answer" => Hive::SecretPatterns.redact(answer.to_s) }
        when "waive_coverage"
          coverage = value.is_a?(Hash) ? value["coverage"] || value[:coverage] : value
          if coverage.to_s.strip.empty?
            raise InvalidAction, "waive_coverage requires a named coverage item"
          end

          { "coverage" => coverage.to_s }
        when "downgrade_level", "raise_level"
          level = value.is_a?(Hash) ? value["level"] || value[:level] : value
          { "level" => Hive::PlanReview.level!(level, label: "decision level") }
        else
          raise InvalidAction, "unknown plan review action #{action.inspect}"
        end
      end

      def normalize_target(action, target, value, review_id, current)
        return target.to_s unless target.to_s.empty?

        case action.to_s
        when "downgrade_level", "raise_level"
          level = value.is_a?(Hash) ? value["level"] || value[:level] : value
          "level-#{level}"
        when "retry"
          attempt_id = current["current_attempt_id"] || latest_review_route(current)&.fetch("attempt_id", nil)
          raise InvalidAction, "retry requires a current transient attempt" unless attempt_id

          attempt_id
        when "request_review"
          if current["blockers"].any? { |entry| entry["reason"] == "verification_finding" }
            return "review-#{review_id}"
          end
          routes = recoverable_terminal_routes(current)
          raise InvalidAction, "request_review requires a terminal reviewer route" if routes.empty?

          Identity.stable_id(
            "review", review_id:, attempts: routes.map { |route| route["attempt_id"] }
          )
        else
          raise InvalidAction, "#{action} requires an exact target fingerprint"
        end
      end

      def validate_observation!(current, decision)
        projection = Projection.new(current)
        checks = {
          "review id" => [ current.review_id, decision["review_id"] ],
          "task generation" => [ current.task_generation.to_s, decision["task_generation"].to_s ],
          "policy fingerprint" => [ current.policy_fingerprint, decision["policy_fingerprint"] ],
          "artifact digest" => [ projection.observation_digest, decision["expected_artifact_digest"] ]
        }
        mismatch = checks.find { |_label, values| values.first != values.last }
        return unless mismatch

        raise StaleDecision, "plan review #{mismatch.first} changed; refresh the current observation"
      end

      def authorize!(decision, authorized:)
        return unless decision.authority_action?
        unless authorized && %w[cli web operator policy].include?(decision["origin"])
          raise UnauthorizedAction, "#{decision.action} requires explicit operator authority"
        end
        if %w[waive_coverage downgrade_level].include?(decision.action) &&
           decision["reason"].to_s.strip.empty?
          raise InvalidAction, "#{decision.action} requires a human-readable reason"
        end
      end

      def apply_to_record(current, decision)
        data = current.to_h
        case decision.action
        when "approve_finding", "answer_finding"
          data["findings"] = update_finding(current, decision)
        when "waive_coverage"
          data["coverage"] = waive_coverage(current, decision)
        when "downgrade_level"
          data["effective_level"] = downgraded_level(current, decision)
        when "raise_level"
          raised_level(current, decision)
        when "retry"
          validate_retry!(current, decision)
          data["routes"] = append_recovery_reset(current, latest_review_route(current))
        when "request_review"
          data["routes"] = reset_terminal_route(current)
        end
        data.merge(
          "state" => "reviewing", "outcome" => nil, "blockers" => [],
          "required_action" => "resume plan review", "degradation_reason" => nil,
          "retry_at" => nil, "execution_allowed" => false
        )
      end

      def update_finding(current, decision)
        found = false
        rows = current["findings"].map do |entry|
          finding = Finding.new(entry)
          next finding.to_h unless finding.fingerprint == decision.target_fingerprint

          found = true
          if decision.action == "approve_finding"
            unless finding.classification == "gated_auto" && finding.blocking?
              raise ConflictingDecision, "finding is not an open gated finding"
            end
            finding.to_h.merge(
              "lifecycle" => "approved", "decision_id" => decision.decision_id
            )
          else
            unless finding.classification == "manual" && finding.blocking?
              raise ConflictingDecision, "finding is not an open manual finding"
            end
            finding.to_h.merge(
              "lifecycle" => "answered", "decision_id" => decision.decision_id,
              "answer" => decision.value.fetch("answer")
            )
          end
        end
        raise InvalidAction, "plan review finding target does not exist" unless found

        rows
      end

      def waive_coverage(current, decision)
        coverage_name = decision.value.fetch("coverage").to_s
        found = false
        rows = current["coverage"].map do |entry|
          fingerprint = entry["fingerprint"] || Identity.coverage(
            review_id: current.review_id, name: entry.fetch("name"),
            policy_fingerprint: current.policy_fingerprint
          )
          next entry.merge("fingerprint" => fingerprint) unless
            fingerprint == decision.target_fingerprint && entry.fetch("name") == coverage_name

          found = true
          entry.merge(
            "fingerprint" => fingerprint, "status" => "waived",
            "reason" => decision["reason"], "decision_id" => decision.decision_id
          )
        end
        raise InvalidAction, "plan review coverage target does not exist" unless found

        rows
      end

      def downgraded_level(current, decision)
        desired = decision.value.fetch("level")
        unless current.effective_level == "mandatory" &&
               LEVEL_RANK.fetch(desired) < LEVEL_RANK.fetch("mandatory")
          raise InvalidAction, "only an effective mandatory review can be explicitly downgraded"
        end
        desired
      end

      def raised_level(current, decision)
        desired = decision.value.fetch("level")
        unless LEVEL_RANK.fetch(desired) > LEVEL_RANK.fetch(current.effective_level)
          raise InvalidAction, "raise_level must increase the current effective level"
        end
        path = File.join(@store.root, "level.json")
        self.class.send(
          :write_raise_receipt!, task: @task, path:, level: desired,
          operator: decision["operator"], reason: decision["reason"], clock: @clock
        )
      end

      def validate_retry!(current, decision)
        route = latest_review_route(current)
        unless route && TRANSIENT_OUTCOMES.include?(route["outcome"])
          raise InvalidAction, "retry is allowed only for a transient plan review outcome"
        end
        unless decision.target_fingerprint == route["attempt_id"]
          raise StaleDecision, "retry target is not the current transient attempt"
        end
      end

      def latest_review_route(current)
        current["routes"].reverse.find do |entry|
          RECOVERABLE_ROLES.include?(entry["role"]) &&
            entry["attempt_id"]
        end
      end

      def reset_terminal_route(current)
        if current["blockers"].any? { |entry| entry["reason"] == "verification_finding" }
          raise InvalidAction,
                "request_review cannot clear a verification finding; create a linked plan generation"
        end
        routes = recoverable_terminal_routes(current)
        raise InvalidAction, "request_review requires a terminal reviewer route" if routes.empty?

        routes.reduce(current["routes"]) do |rows, route|
          append_recovery_reset(current.to_h.merge("routes" => rows), route)
        end
      end

      def append_recovery_reset(current, route)
        reset = Hive::PlanReview.recovery_reset_route(route)
        current["routes"] + [ reset ]
      end

      def recoverable_terminal_routes(current)
        RECOVERABLE_ROLES.filter_map do |role|
          current["routes"].reverse.find { |entry| entry["role"] == role }
        end.select do |entry|
          RECOVERABLE_TERMINAL_OUTCOMES.include?(entry["outcome"])
        end
      end

      def validate_current_freshness!(current)
        task = Hive::Task.new(@task.folder)
        freshness = TransitionGuard.freshness(
          task:, projection: Projection.new(current), config: Hive::Config.load(task.project_root)
        )
        return if freshness.fetch("status") == "current"

        raise StaleDecision, "plan review changed; refresh the current observation"
      end

      def timestamp = @clock.call.utc.iso8601(6)

      def commit!(action)
        Hive::GitOps.new(@task.project_root).hive_commit(
          stage_name: "#{@task.stage_index}-#{@task.stage_name}",
          slug: @task.slug, action: "plan review #{action}"
        )
      end
    end
  end
end
