require "test_helper"
require "open3"
require "hive/plan_review/plan_signals"
require "hive/stages/open_pr"
require "hive/plan_review/plan_signals"

class GoldenPathSupportTest < ActiveSupport::TestCase
  FAKE_CLAUDE = File.expand_path("support/claude", __dir__)

  test "plan fake authors a bounded plan that does not launch a real reviewer" do
    Dir.mktmpdir("golden-path-plan") do |root|
      task_folder = File.join(root, "stages", "3-plan", "sample-task")
      FileUtils.mkdir_p(task_folder)

      _stdout, stderr, status = Open3.capture3(FAKE_CLAUDE, chdir: task_folder)

      assert status.success?, stderr
      signals = Hive::PlanReview::PlanSignals.analyze(
        plan_path: File.join(task_folder, "plan.md"),
        task_folder:
      )
      assert signals.skip_eligible?, signals.to_h.inspect
    end
  end

  test "open-PR fake authors the bounded draft consumed by the controller" do
    Dir.mktmpdir("golden-path-open-pr") do |root|
      task_folder = File.join(root, "stages", "5-open-pr", "sample-task")
      FileUtils.mkdir_p(task_folder)

      _stdout, stderr, status = Open3.capture3(FAKE_CLAUDE, chdir: task_folder)

      assert status.success?, stderr
      path = File.join(task_folder, Hive::Stages::OpenPr::AUTHORING_FILE)
      assert_path_exists path
      draft = JSON.parse(File.binread(path))
      assert_equal "Golden path sample implementation", draft.fetch("title")
      assert_equal "Created by the golden-path E2E.", draft.fetch("body")
      assert_operator File.size(path), :<=, Hive::Stages::OpenPr::MAX_AUTHORING_BYTES
    end
  end

  test "plan fake emits an explicitly tested reversible plan eligible to skip review" do
    Dir.mktmpdir("golden-path-plan") do |root|
      task_folder = File.join(root, "stages", "3-plan", "sample-task")
      FileUtils.mkdir_p(task_folder)

      _stdout, stderr, status = Open3.capture3(FAKE_CLAUDE, chdir: task_folder)

      assert status.success?, stderr
      signals = Hive::PlanReview::PlanSignals.analyze(
        plan_path: File.join(task_folder, "plan.md"), task_folder: task_folder
      )
      assert signals.skip_eligible?, signals.to_h.inspect
    end
  end
end
