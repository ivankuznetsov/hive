require "shellwords"
require "hive/conditions/gate_evaluator"
require "hive/conditions/migration"
require "hive/conditions/recovery_action"
require "hive/plan_frontmatter"
require "hive/task_projection/store"

module Hive
  module Conditions
    module TransitionGuard
      module_function

      EXECUTE_STAGE = "4-execute" # coding-scoped: condition rollout currently governs coding execute
      OPEN_PR_STAGE = "5-open-pr" # coding-scoped: execute condition gate advances into coding open-pr

      def validate!(task, config: nil, force: false, source: "transition_guard")
        return true unless "#{task.stage_index}-#{task.stage_name}" == "4-execute" # coding-scoped: increment 1 guards coding execute

        config ||= Hive::Config.load(task.project_root)
        return true if Hive::Conditions::Migration.configured_mode(config, EXECUTE_STAGE) == "markers"

        rule = task.workflow.stage_named("execute")&.condition_policy ||
               Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
        return true unless Hive::Conditions::Migration.authority_capable?(
          rule: rule, stage: EXECUTE_STAGE
        )

        marker = Hive::Markers.current(task.state_file)
        projection_store = Hive::TaskProjection::Store.new(task_folder: task.folder)
        projection = projection_store.read(marker: marker)
        selection = Hive::Conditions::Migration.selection(
          config: config, stage: EXECUTE_STAGE, projection: projection,
          rule: rule # coding-scoped: increment 1 guards coding execute
        )
        return true unless selection.effective == "conditions"

        research = research_execution?(task)
        result = Hive::Conditions::GateEvaluator.new(projection: projection, rule: rule).evaluate(
          research: research
        )
        if force
          audit_force!(
            task: task, projection: projection, projection_store: projection_store,
            marker: marker, result: result, source: source
          ) unless result.eligible?
          return true
        end
        return true if result.eligible?

        details = result.diagnostics.map do |diagnostic|
          "#{diagnostic['condition']}=#{diagnostic['state']}(#{diagnostic['reason']})"
        end.join(", ")
        raise Hive::ConditionGateBlocked.new(
          "execute condition gate blocks forward transition: #{details}",
          current_stage: EXECUTE_STAGE, target_stage: OPEN_PR_STAGE,
          condition_gate: result.to_h,
          next_action: Hive::Conditions::RecoveryAction.build(
            task: task, gate: result,
            rerun_with: "hive develop #{task.folder.shellescape} --from 4-execute"
          )
        )
      end

      def audit_force!(task:, projection:, projection_store:, marker:, result:, source:)
        data = projection.to_h
        attempt_id = data.dig("identity", "attempt_id")
        binding = Array(data.dig("journal", "attempts")).find do |entry|
          entry["attempt_id"] == attempt_id
        end
        unless binding
          raise Hive::TaskProjection::InvalidJournal,
                "condition override cannot identify its durable attempt"
        end

        payload = {
          "transition" => result.transition,
          "from_stage" => EXECUTE_STAGE,
          "to_stage" => OPEN_PR_STAGE,
          "waived_diagnostics" => result.diagnostics,
          "source_command" => source.to_s
        }
        records = Hive::TaskProjection.read_journal(
          projection_store.journal_path, attempt_store: projection_store.attempt_store
        )
        duplicate = records.any? do |record|
          record["event_type"] == "operator_action" &&
            record["attempt_id"] == attempt_id &&
            record["reason"] == "forced_condition_transition" &&
            record["payload"] == payload
        end
        return if duplicate

        Hive::TaskJournal::Writer.new(
          task_folder: task.folder, attempt_store: projection_store.attempt_store
        ).append(
          event_type: "operator_action",
          task: {
            "id" => task.respond_to?(:id) ? task.id&.to_s : nil,
            "slug" => task.slug.to_s
          },
          workflow: task.workflow.id.to_s,
          stage: EXECUTE_STAGE,
          attempt_id: attempt_id,
          task_generation: binding.fetch("task_generation"),
          ownership_generation: binding["ownership_generation"],
          commit_generation: data.dig("identity", "commit_generation") || 0,
          reason: "forced_condition_transition",
          evidence: [],
          provenance: {
            "source" => "operator_override",
            "source_command" => source.to_s,
            "pid" => Process.pid
          },
          payload: payload
        )
        projection_store.rebuild!(marker: marker)
      end

      def research_execution?(task)
        path = File.join(task.folder, "plan.md")
        result = Hive::PlanFrontmatter.read(path)
        result.valid? && result.data["execution_mode"].to_s == "research"
      end
    end
  end
end
