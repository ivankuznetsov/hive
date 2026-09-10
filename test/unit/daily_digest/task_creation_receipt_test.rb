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

  def test_filesystem_failures_and_malformed_receipts_are_typed
    with_tmp_dir do |task_folder|
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*, **) { raise Errno::EACCES, "denied" }
      ) do
        assert_raises(Hive::DailyDigest::TaskCreationReceipt::Error) do
          write_receipt(task_folder)
        end
      end

      assert_raises(Hive::DailyDigest::TaskCreationReceipt::InvalidReceipt) do
        Hive::DailyDigest::TaskCreationReceipt.read!(task_folder)
      end
      File.binwrite(File.join(task_folder, "task-creation.json"), "not-json")
      assert_raises(Hive::DailyDigest::TaskCreationReceipt::InvalidReceipt) do
        Hive::DailyDigest::TaskCreationReceipt.read!(task_folder)
      end
      File.binwrite(File.join(task_folder, "task-creation.json"), "{}")
      assert_raises(Hive::DailyDigest::TaskCreationReceipt::InvalidReceipt) do
        Hive::DailyDigest::TaskCreationReceipt.read!(task_folder)
      end
    end
  end

  def test_validation_rejects_unsupported_invalid_and_tampered_receipts
    mod = Hive::DailyDigest::TaskCreationReceipt
    assert_raises(mod::InvalidReceipt) { mod.send(:validate!, {}) }

    valid = mod.send(
      :build,
      project: { "project_id" => "project-1", "name" => "demo" },
      task: { "id" => 42, "slug" => "new-task" },
      workflow: "coding", stage: "1-inbox", created_at: "2026-08-30T10:00:00Z"
    )
    assert_raises(mod::InvalidReceipt) do
      mod.send(:validate!, valid.merge("creation_id" => "not-a-digest"))
    end
    assert_raises(mod::InvalidReceipt) do
      mod.send(:validate!, valid.merge("creation_id" => "0" * 64))
    end
    assert_raises(mod::InvalidReceipt) do
      mod.send(:validate!, valid.merge("created_at" => "bad-time"))
    end
    assert_raises(mod::InvalidReceipt) do
      mod.send(:required_text, "bad\ntext", "label", 160)
    end
    assert_equal({}, mod.send(:stringify, Object.new))
  end

  private

  def write_receipt(task_folder)
    Hive::DailyDigest::TaskCreationReceipt.write!(
      task_folder: task_folder,
      project: { "project_id" => "project-1", "name" => "demo" },
      task: { "id" => 42, "slug" => "new-task" },
      workflow: "coding", stage: "1-inbox",
      created_at: Time.iso8601("2026-08-30T10:00:00Z")
    )
  end
end
