require "test_helper"
require "hive/plan_review/automation"

class PlanReviewAutomationTest < Minitest::Test
  include HiveTestHelper

  Workflow = Struct.new(:id, keyword_init: true)
  Task = Struct.new(
    :folder, :project_root, :hive_state_path, :slug, :id, :workflow,
    :meta_yml_path, :stage_index, :stage_name, :state_file,
    keyword_init: true
  )

  ReviewRecord = Struct.new(:execution_allowed?)
  ReviewProjection = Struct.new(:record)

  def test_runs_the_orchestrator_under_the_task_lock_without_operator_authority
    with_task do |task|
      expected = ReviewProjection.new(ReviewRecord.new(true))
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

  def test_falls_back_to_the_real_orchestrator_when_none_is_injected
    with_task do |task|
      expected = ReviewProjection.new(ReviewRecord.new(true))
      observed = nil
      replacement = lambda do |task:, cfg:, planner_identity:|
        observed = { task:, cfg:, planner_identity: }
        expected
      end

      result = with_replaced_singleton_method(
        Hive::PlanReview::Orchestrator, :run!, replacement
      ) do
        Hive::PlanReview::Automation.run!(task:, config: Hive::Config::DEFAULTS)
      end

      assert_same expected, result
      assert_same task, observed.fetch(:task)
      assert_equal "claude", observed.dig(:planner_identity, "provider")
    end
  end

  def test_legacy_codex_planner_identity_is_repaired_before_resume
    current = {
      "routes" => [
        {
          "role" => "planner",
          "actual" => {
            "provider" => "codex", "model" => "claude-opus-4-8",
            "family" => "openai", "effort" => "default", "route" => "codex-cli/v1"
          }
        }
      ]
    }

    identity = Hive::PlanReview::Automation.planner_identity_for(
      current, Hive::Config::DEFAULTS
    )

    assert_equal "codex", identity.fetch("provider")
    assert_equal "default", identity.fetch("model")
    assert_equal true, identity.fetch("reconstructed")
  end

  def test_holds_a_complete_plan_at_waiting_until_required_review_clears
    with_task do |task|
      File.write(task.state_file, "# Plan\n<!-- COMPLETE -->\n")
      projection = ReviewProjection.new(ReviewRecord.new(false))

      result = Hive::PlanReview::Automation.run!(
        task:, config: Hive::Config::DEFAULTS,
        orchestrator: ->(**) { projection }
      )

      assert_same projection, result
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  def test_leaves_a_complete_plan_terminal_after_review_clearance
    with_task do |task|
      File.write(task.state_file, "# Plan\n<!-- COMPLETE -->\n")
      projection = ReviewProjection.new(ReviewRecord.new(true))

      Hive::PlanReview::Automation.run!(
        task:, config: Hive::Config::DEFAULTS,
        orchestrator: ->(**) { projection }
      )

      assert_equal :complete, Hive::Markers.current(task.state_file).name
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
        stage_index: 3, stage_name: "plan", state_file: File.join(folder, "plan.md")
      )
      yield task
    end
  end
end
