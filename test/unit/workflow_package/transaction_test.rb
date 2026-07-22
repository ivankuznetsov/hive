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

  def test_reconcile_keeps_new_pointer_when_git_commit_completed_before_process_death
    with_transaction_repo do |root, workflows, lock|
      old = "{\"old\":true}\n"
      new_bytes = "{\"new\":true}\n"
      File.write(lock, new_bytes)
      File.write(File.join(workflows, ".transaction.json"), Hive::WorkflowPackage::CanonicalJSON.generate(
        "schema_version" => 1, "phase" => "commit_started", "lock_path" => lock,
        "old_lock" => old, "new_lock" => new_bytes
      ))
      run!("git", "-C", root, "add", "workflows/demo/honeycomb.lock.json")
      run!("git", "-C", root, "commit", "-m", "activate", "--quiet")

      assert Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: workflows).reconcile!
      assert_equal new_bytes, File.read(lock)
    end
  end

  def test_reconcile_restores_old_pointer_when_commit_started_but_did_not_land
    with_transaction_repo do |_root, workflows, lock|
      old = "{\"old\":true}\n"
      new_bytes = "{\"new\":true}\n"
      File.write(lock, new_bytes)
      Hive::WorkflowPackage::TransactionJournal.new(workflows).write(
        "schema_version" => 1, "phase" => "commit_started", "lock_path" => lock,
        "old_lock" => old, "new_lock" => new_bytes
      )

      assert Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: workflows).reconcile!
      assert_equal old, File.read(lock)
    end
  end

  def test_reconcile_keeps_new_pointer_after_completed_commit_phase
    with_tmp_dir do |dir|
      lock = File.join(dir, "demo", "honeycomb.lock.json")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{\"old\":true}\n")
      Hive::WorkflowPackage::TransactionJournal.new(dir).write(
        "schema_version" => 1, "phase" => "commit_completed", "lock_path" => lock,
        "old_lock" => "{\"old\":true}\n", "new_lock" => "{\"new\":true}\n"
      )

      assert Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: dir).reconcile!
      assert_equal "{\"new\":true}\n", File.read(lock)
    end
  end

  def test_reconcile_keeps_a_committed_removal
    with_transaction_repo do |root, workflows, lock|
      old = File.read(lock)
      FileUtils.rm_f(lock)
      run!("git", "-C", root, "add", "workflows/demo/honeycomb.lock.json")
      run!("git", "-C", root, "commit", "-m", "remove selection", "--quiet")
      Hive::WorkflowPackage::TransactionJournal.new(workflows).write(
        "schema_version" => 1, "phase" => "commit_started", "lock_path" => lock,
        "old_lock" => old, "new_lock" => nil
      )

      assert Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: workflows).reconcile!
      refute File.exist?(lock)
    end
  end

  def test_reconcile_rejects_an_unknown_journal_phase
    with_tmp_dir do |dir|
      lock = File.join(dir, "demo", "honeycomb.lock.json")
      Hive::WorkflowPackage::TransactionJournal.new(dir).write(
        "schema_version" => 1, "phase" => "future", "lock_path" => lock,
        "old_lock" => nil, "new_lock" => nil
      )

      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: dir).reconcile!
      end
    end
  end

  def test_reconcile_restores_old_pointer_when_git_cannot_be_inspected
    with_tmp_dir do |dir|
      lock = File.join(dir, "demo", "honeycomb.lock.json")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{\"new\":true}\n")
      Hive::WorkflowPackage::TransactionJournal.new(dir).write(
        "schema_version" => 1, "phase" => "commit_started", "lock_path" => lock,
        "old_lock" => "{\"old\":true}\n", "new_lock" => "{\"new\":true}\n"
      )

      with_env("PATH" => "") do
        assert Hive::WorkflowPackage::Transaction.new(lock_path: lock, workflows_dir: dir).reconcile!
      end
      assert_equal "{\"old\":true}\n", File.read(lock)
    end
  end

  def test_malformed_journal_fails_closed
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".transaction.json"), "{not-json")

      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::TransactionJournal.new(dir).read
      end
    end
  end

  def test_mutation_lock_wraps_filesystem_failures
    with_tmp_dir do |dir|
      blocked = File.join(dir, "not-a-directory")
      File.write(blocked, "file")

      assert_raises(Hive::ConcurrentRunError) do
        Hive::WorkflowPackage::MutationLock.with_lock(blocked) { flunk "lock should not be acquired" }
      end
    end
  end

  private

  def with_transaction_repo
    with_tmp_git_repo do |root|
      workflows = File.join(root, "workflows")
      lock = File.join(workflows, "demo", "honeycomb.lock.json")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{\"old\":true}\n")
      run!("git", "-C", root, "add", "workflows/demo/honeycomb.lock.json")
      run!("git", "-C", root, "commit", "-m", "old selection", "--quiet")
      yield root, workflows, lock
    end
  end
end
