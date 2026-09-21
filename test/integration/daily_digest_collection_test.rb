require "test_helper"
require "hive/daily_digest/collector"

class DailyDigestCollectionTest < Minitest::Test
  include HiveTestHelper

  def test_one_unreadable_project_does_not_hide_healthy_project_activity
    with_tmp_dir do |root|
      healthy = File.join(root, "healthy")
      missing = File.join(root, "missing")
      task = File.join(healthy, ".hive-state", "stages", "1-inbox", "new-task")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "idea.md"), "# idea\n")
      Hive::DailyDigest::TaskCreationReceipt.write!(
        task_folder: task,
        project: { "project_id" => "healthy-id", "name" => "healthy" },
        task: { "id" => 1, "slug" => "new-task" },
        workflow: "coding", stage: "1-inbox",
        created_at: Time.iso8601("2026-08-30T08:00:00Z")
      )

      result = Hive::DailyDigest::Collector.new(
        projects: [ project("healthy-id", "healthy", healthy), project("missing-id", "missing", missing) ],
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z")
      ).collect

      assert_equal [ "task_created" ], result.facts.map { |fact| fact.fetch("kind") }
      assert_equal [ "missing" ], result.gaps.map { |gap| gap.fetch("scope") }
      assert_equal "partial", result.completeness
    end
  end

  private

  def project(id, name, path)
    {
      "project_id" => id, "registration_id" => "registration-#{id}",
      "name" => name, "path" => path,
      "hive_state_path" => File.join(path, ".hive-state")
    }
  end
end
