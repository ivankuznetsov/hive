require "test_helper"
require "json"
require "hive/workflow_package/transaction"

class WorkflowPackageTransactionTest < Minitest::Test
  include HiveTestHelper

  def test_commit_failure_restores_old_pointer_and_clears_journal
    with_tmp_dir do |dir|
      lock = File.join(dir, "demo", "honeycomb.lock.json")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{\"old\":true}\n")

      assert_raises(Hive::GitError) do
        Hive::WorkflowPackage::Transaction.activate(
          lock_path: lock, workflows_dir: dir, new_lock: { "new" => true },
          commit: -> { raise Hive::GitError, "commit failed" }
        )
      end

      assert_equal "{\"old\":true}\n", File.read(lock)
      refute File.exist?(File.join(dir, ".transaction.json"))
    end
  end

  def test_reconcile_restores_old_pointer_after_interrupted_activation
    with_tmp_dir do |dir|
      lock = File.join(dir, "demo", "honeycomb.lock.json")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{\"new\":true}\n")
      journal = Hive::WorkflowPackage::TransactionJournal.new(dir)
      journal.write(
        "schema_version" => 1, "phase" => "pointer_written", "lock_path" => lock,
        "old_lock" => "{\"old\":true}\n", "new_lock" => "{\"new\":true}\n"
      )

      assert Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: dir).reconcile!
      assert_equal "{\"old\":true}\n", File.read(lock)
      refute File.exist?(journal.path)
    end
  end
end
