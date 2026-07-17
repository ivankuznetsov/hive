require "yaml"
require "hive/conditions/gate_evaluator"
require "hive/conditions/migration"
require "hive/task_projection/store"

module Hive
  module Conditions
    module TransitionGuard
      module_function

      def validate!(task, config: nil, force: false)
        return true if force
        return true unless "#{task.stage_index}-#{task.stage_name}" == "4-execute" # coding-scoped: increment 1 guards coding execute

        config ||= Hive::Config.load(task.project_root)
        marker = Hive::Markers.current(task.state_file)
        projection = Hive::TaskProjection::Store.new(task_folder: task.folder).read(marker: marker)
        selection = Hive::Conditions::Migration.selection(
          config: config, stage: "4-execute", projection: projection # coding-scoped: increment 1 guards coding execute
        )
        return true unless selection.effective == "conditions"

        rule = task.workflow.stage_named("execute")&.condition_policy ||
               Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
        research = research_execution?(task)
        result = Hive::Conditions::GateEvaluator.new(projection: projection, rule: rule).evaluate(
          research: research, research_evidence: research_output?(task)
        )
        return true if result.eligible?

        details = result.diagnostics.map do |diagnostic|
          "#{diagnostic['condition']}=#{diagnostic['state']}(#{diagnostic['reason']})"
        end.join(", ")
        raise Hive::WrongStage,
              "execute condition gate blocks forward transition: #{details}"
      end

      def research_execution?(task)
        path = File.join(task.folder, "plan.md")
        return false unless File.file?(path)

        frontmatter = File.read(path).match(/\A---\s*\n(.*?)\n---\s*\n/m)&.captures&.first
        data = frontmatter && YAML.safe_load(frontmatter)
        data.is_a?(Hash) && data["execution_mode"].to_s == "research"
      rescue Psych::Exception, SystemCallError
        false
      end

      def research_output?(task)
        File.read(task.state_file).include?("## Execute Output")
      rescue SystemCallError
        false
      end
    end
  end
end
