require "test_helper"
require "hive/plan_review/planner_revision"

class PlanReviewPlannerRevisionTest < Minitest::Test
  Task = Struct.new(:folder, keyword_init: true)

  def test_accepts_one_complete_candidate_and_leaves_input_plan_untouched
    Dir.mktmpdir("hive-plan-revision") do |root|
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      canonical = File.join(task_folder, "plan.md")
      File.write(canonical, "# Original\n<!-- COMPLETE -->\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, "# Revised\n<!-- COMPLETE -->\n")
        { "status" => "success", "actual_route" => planner_identity }
      end
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder), cfg: {}, runner:
      )

      result = service.call(
        review_id: "pr-#{'a' * 64}", plan_bytes: File.binread(canonical), findings: [],
        planner_identity:, timeout_sec: 60
      )

      assert result.success?
      assert_equal "# Revised\n<!-- COMPLETE -->\n", result.candidate_bytes
      assert_equal "# Original\n<!-- COMPLETE -->\n", File.binread(canonical)
    end
  end

  def test_rejects_waiting_candidate
    Dir.mktmpdir("hive-plan-revision") do |root|
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      runner = lambda do |output_path:, **|
        File.write(output_path, "# Revised\n<!-- WAITING -->\n")
        { "status" => "success" }
      end
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder), cfg: {}, runner:
      )
      result = service.call(
        review_id: "pr-#{'b' * 64}", plan_bytes: "# Plan\n", findings: [],
        planner_identity:, timeout_sec: 60
      )

      assert_equal "terminal_failure", result.outcome
      assert_match(/COMPLETE/, result.diagnostic)
    end
  end

  def test_rejects_candidate_before_allocating_more_than_the_byte_limit
    Dir.mktmpdir("hive-plan-revision") do |root|
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      runner = lambda do |output_path:, **|
        File.binwrite(
          output_path,
          "a" * (Hive::PlanReview::PlannerRevision::MAX_CANDIDATE_BYTES + 1)
        )
        { "status" => "success" }
      end
      result = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder), cfg: {}, runner:
      ).call(
        review_id: "pr-#{'c' * 64}", plan_bytes: "# Plan\n", findings: [],
        planner_identity:, timeout_sec: 60
      )

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "size limit"
    end
  end

  private

  def planner_identity
    {
      "provider" => "claude", "model" => "opus", "family" => "anthropic",
      "effort" => "high", "route" => "native_claude"
    }
  end
end
