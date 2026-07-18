require "hive/attempts/context"
require "hive/attempts/store"
require "hive/conditions/gate_evaluator"
require "hive/conditions/migration"
require "hive/conditions/reconcilers/execute"
require "hive/conditions/shadow_audit"
require "hive/markers"
require "hive/paths"

module Hive
  module Conditions
    BoundaryOutcome = Data.define(
      :marker_name, :marker_attrs, :commit, :status, :projection, :gate, :selection
    )

    class ExecuteBoundary
      EXECUTE_STAGE = "4-execute" # coding-scoped: condition rollout currently governs coding execute

      def initialize(task:, config:, worktree_path:, attempt_store: nil, context: nil,
                     writer: nil, projection_store: nil, git_ops: nil)
        @task = task
        @config = config
        @worktree_path = worktree_path
        @context = context || Hive::Attempts::Context.current
        @attempt_store = attempt_store || default_attempt_store
        @attempt = @context && @attempt_store&.fetch(@context.attempt_id)
        @writer = writer || Hive::TaskJournal::Writer.new(
          task_folder: task.folder, attempt_store: @attempt_store
        )
        @projection_store = projection_store || Hive::TaskProjection::Store.new(
          task_folder: task.folder, attempt_store: @attempt_store
        )
        @git_ops = git_ops || Hive::GitOps.new(worktree_path)
      end

      def evaluate(legacy_marker_name:, legacy_attrs: {}, legacy_commit:, legacy_status:,
                   baseline_head:, waiting_reason: nil, research: false,
                   research_evidence: false, category: nil)
        return legacy_boundary(
          marker_name: legacy_marker_name, attrs: legacy_attrs,
          commit: legacy_commit, status: legacy_status,
          head_sha: safe_head, branch: safe_branch
        ) unless @context

        unless @attempt
          raise Hive::Conditions::GenerationMismatch,
                "execute boundary durable attempt #{@context.attempt_id} is unavailable"
        end

        verify_context!
        reconciliation = reconcile(
          baseline_head: baseline_head, waiting_reason: waiting_reason, research: research,
          research_evidence: research_evidence
        )
        projection = reconciliation.projection
        gate = gate_for(projection, research: research, research_evidence: research_evidence)
        if gate.reconcile_required?
          reconciliation = reconcile(
            baseline_head: baseline_head, waiting_reason: waiting_reason, research: research,
            research_evidence: research_evidence
          )
          projection = reconciliation.projection
          gate = gate_for(projection, research: research, research_evidence: research_evidence)
        end
        selection = Hive::Conditions::Migration.selection(
          config: @config, stage: EXECUTE_STAGE, projection: projection,
          rule: execute_rule # coding-scoped: increment 1 gates coding execute only
        )
        condition_marker, condition_attrs, condition_commit, condition_status = condition_outcome(
          gate, research: research
        )

        if selection.effective == "shadow"
          projection = append_shadow_audit(
            projection: projection,
            category: category || category_for(legacy_marker_name, legacy_attrs, projection: projection),
            marker_action: legacy_marker_name.to_s, condition_action: condition_marker.to_s
          )
          if legacy_marker_name.to_s != condition_marker.to_s
            warn "hive: execute condition shadow mismatch: marker=#{legacy_marker_name} " \
                 "conditions=#{condition_marker}"
          end
        end

        # Operational failures stay errors in every authority mode. Conditions
        # decide advancement, but must never turn a failed agent/git probe into
        # an ordinary waiting outcome after the boundary has journaled it.
        if selection.effective == "conditions" && legacy_marker_name.to_sym != :error
          BoundaryOutcome.new(
            marker_name: condition_marker, marker_attrs: condition_attrs,
            commit: condition_commit, status: condition_status,
            projection: projection, gate: gate, selection: selection
          )
        else
          BoundaryOutcome.new(
            marker_name: legacy_marker_name, marker_attrs: legacy_attrs,
            commit: legacy_commit, status: legacy_status,
            projection: projection, gate: gate, selection: selection
          )
        end
      end

      private

      def default_attempt_store
        return nil unless @context

        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        Hive::Attempts::Store.new(root: root.empty? ? Hive::Paths.attempts_root : root)
      end

      def verify_context!
        unless @attempt.attempt_id == @context.attempt_id &&
               @attempt.task_input_epoch == @context.task_generation &&
               (@context.ownership_generation.nil? ||
                @attempt.ownership_generation == @context.ownership_generation)
          raise Hive::Conditions::GenerationMismatch,
                "execute boundary attempt context does not match durable attempt"
        end
      end

      def reconcile(baseline_head:, waiting_reason:, research:, research_evidence:)
        Hive::Conditions::Reconcilers::Execute.new(
          task: @task, attempt: @attempt, attempt_store: @attempt_store,
          writer: @writer, projection_store: @projection_store, git_ops: @git_ops,
          workflow_policy: execute_rule.to_h
        ).reconcile(
          baseline_head: baseline_head, waiting_reason: waiting_reason, research: research,
          research_evidence: research_evidence
        )
      end

      def gate_for(projection, research:, research_evidence:)
        Hive::Conditions::GateEvaluator.new(
          projection: projection, rule: execute_rule
        ).evaluate(research: research, research_evidence: research_evidence)
      end

      def execute_rule
        stage = @task.respond_to?(:workflow) ? @task.workflow&.stage_named("execute") : nil
        stage&.condition_policy || Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
      end

      def condition_outcome(gate, research:)
        if gate.eligible?
          attrs = research ? { mode: "research" } : {}
          return [ :execute_complete, attrs, "execute_complete", :execute_complete ]
        end

        diagnostic = gate.diagnostics.first || {}
        reason = diagnostic["reason"].to_s
        reason = diagnostic["state"] == "unverifiable" ? "condition_unverifiable" :
          "condition_pending" if reason.empty?
        [
          :execute_waiting,
          { reason: reason, condition: diagnostic["condition"], condition_state: diagnostic["state"] },
          "execute_waiting_#{reason}",
          :execute_waiting
        ]
      end

      def legacy_boundary(marker_name:, attrs:, commit:, status:, head_sha:, branch:)
        Hive::Conditions::Migration.ensure_legacy_baseline!(
          task: @task, writer: @writer, marker: Hive::Markers.current(@task.state_file),
          head_sha: head_sha, branch: branch
        )
        projection = @projection_store.rebuild!
        selection = Hive::Conditions::Migration.selection(
          config: @config, stage: EXECUTE_STAGE, projection: projection,
          rule: execute_rule # coding-scoped: increment 1 gates coding execute only
        )
        BoundaryOutcome.new(
          marker_name: marker_name, marker_attrs: attrs, commit: commit, status: status,
          projection: projection, gate: nil, selection: selection
        )
      end

      def append_shadow_audit(projection:, category:, marker_action:, condition_action:)
        identity = projection["identity"]
        records = Hive::TaskProjection.read_journal(
          @writer.path, attempt_store: @writer.attempt_store
        )
        existing = records.any? do |record|
          record["event_type"] == "shadow_audit" &&
            record["attempt_id"] == @attempt.attempt_id &&
            record["task_generation"] == identity.fetch("task_generation") &&
            record["commit_generation"] == identity.fetch("commit_generation") &&
            record.dig("payload", "category") == category &&
            record.dig("payload", "marker_action") == marker_action &&
            record.dig("payload", "condition_action") == condition_action
        end
        return projection if existing

        event = Hive::Conditions::ShadowAudit.event(
          task: @task, attempt: @attempt,
          task_generation: identity.fetch("task_generation"),
          commit_generation: identity.fetch("commit_generation"),
          category: category, marker_action: marker_action,
          condition_action: condition_action
        )
        @writer.append(event)
        @projection_store.rebuild!
      end

      def category_for(marker_name, attrs, projection:)
        reason = attrs.to_h[:reason] || attrs.to_h["reason"]
        return "research_success" if attrs.to_h[:mode] == "research" || attrs.to_h["mode"] == "research"
        return "no_change" if reason == "no_worktree_changes"
        return "agent_loss" if %w[implementer_failed limits_reached].include?(reason.to_s) ||
                               reason.to_s.include?("agent") || reason.to_s.include?("attempt")
        return "operator_repair" if reason.to_s.include?("repair")
        return "operator_repair" if marker_name.to_sym == :execute_complete && repair_history?(projection)

        marker_name.to_sym == :execute_complete ? "commit_success" : "no_change"
      end

      def repair_history?(projection)
        projection["conditions"].fetch("history").any? do |fact|
          (fact["condition"] == "AgentHealthy" && fact["original_state"] == "unsatisfied") ||
            (fact["condition"] == "AwaitingHuman" && fact["original_state"] == "satisfied")
        end
      end

      def safe_head
        @git_ops.head_sha
      rescue Hive::GitError, SystemCallError
        nil
      end

      def safe_branch
        @git_ops.current_branch
      rescue Hive::GitError, SystemCallError
        nil
      end
    end
  end
end
