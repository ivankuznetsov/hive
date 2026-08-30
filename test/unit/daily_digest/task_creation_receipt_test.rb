require "test_helper"
require "hive/daily_digest/task_creation_receipt"

class DailyDigestTaskCreationReceiptTest < Minitest::Test
  include HiveTestHelper

  def test_write_is_private_deterministic_and_conflict_checked
    with_tmp_dir do |task_folder|
      receipt = Hive::DailyDigest::TaskCreationReceipt.write!(
        task_folder: task_folder,
        project: { "project_id" => "project-1", "name" => "demo" },
        task: { "id" => 42, "slug" => "new-task" },
        workflow: "coding", stage: "1-inbox",
        created_at: Time.iso8601("2026-08-30T10:00:00Z")
      )

      assert_equal receipt,
                   Hive::DailyDigest::TaskCreationReceipt.read!(task_folder)
      assert_equal receipt.fetch("creation_id"),
                   Hive::DailyDigest::TaskCreationReceipt.write!(
                     task_folder: task_folder,
                     project: { "project_id" => "project-1", "name" => "demo" },
                     task: { "id" => 42, "slug" => "new-task" },
                     workflow: "coding", stage: "1-inbox",
                     created_at: Time.iso8601("2026-08-30T10:00:00Z")
                   ).fetch("creation_id")
      assert_equal 0o600,
                   File.stat(File.join(task_folder, "task-creation.json")).mode & 0o777

      assert_raises(Hive::DailyDigest::TaskCreationReceipt::Conflict) do
        Hive::DailyDigest::TaskCreationReceipt.write!(
          task_folder: task_folder,
          project: { "project_id" => "project-1", "name" => "demo" },
          task: { "id" => 42, "slug" => "other" },
          workflow: "coding", stage: "1-inbox",
          created_at: Time.iso8601("2026-08-30T10:00:00Z")
        )
      end
    end
  end
end
