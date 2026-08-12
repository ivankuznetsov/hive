require "test_helper"
require "hive/plan_review/automation"

class PlanReviewAutomationTest < Minitest::Test
  Workflow = Struct.new(:id, keyword_init: true)
  Task = Struct.new(
    :folder, :project_root, :hive_state_path, :slug, :id, :workflow,
    :meta_yml_path, :stage_index, :stage_name,
    keyword_init: true
  )

  def test_runs_the_orchestrator_under_the_task_lock_without_operator_authority
    with_task do |task|
      expected = Object.new
      observed = nil
      orchestrator = lambda do |task:, cfg:, planner_identity:|
        observed = { task:, cfg:, planner_identity: }
        assert File.exist?(File.join(task.folder, ".lock"))
        expected
      end

      result = Hive::PlanReview::Automation.run!(
        task:, config: Hive::Config::DEFAULTS, orchestrator:
      )

      assert_same expected, result
      assert_same task, observed.fetch(:task)
      assert_equal "claude", observed.dig(:planner_identity, "provider")
      refute File.exist?(File.join(task.folder, ".lock"))
    end
  end

  def test_rejects_non_coding_or_non_plan_tasks
    with_task(workflow: "custom") do |task|
      assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::Automation.run!(
          task:, config: Hive::Config::DEFAULTS,
          orchestrator: ->(**) { flunk "must not run" }
        )
      end
    end
  end

  private

  def with_task(workflow: "coding")
    Dir.mktmpdir("plan-review-automation") do |root|
      folder = File.join(
        root, ".hive-state", "stages", "3-plan", "automation-260812-abcd"
      )
      FileUtils.mkdir_p(folder)
      meta = File.join(folder, "meta.yml")
      File.write(meta, "id: 7\n")
      task = Task.new(
        folder:, project_root: root, hive_state_path: File.join(root, ".hive-state"),
        slug: "automation-260812-abcd", id: 7,
        workflow: Workflow.new(id: workflow), meta_yml_path: meta,
        stage_index: 3, stage_name: "plan"
      )
      yield task
    end
  end
end
