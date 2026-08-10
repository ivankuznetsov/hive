require "test_helper"
require "hive/module_package/transaction"
require "hive/workflow_package/canonical_json"

class ModulePackageTransactionTest < Minitest::Test
  include HiveTestHelper

  def test_reconcile_restores_a_provisional_pointer_and_runtime_hooks
    with_tmp_dir do |root|
      module_dir = File.join(root, "modules", "demo")
      FileUtils.mkdir_p(File.join(module_dir, "runtime"))
      old_selection = Hive::WorkflowPackage::CanonicalJSON.generate("old" => true)
      old_hooks = Hive::WorkflowPackage::CanonicalJSON.generate("hooks" => {})
      old_setup = Hive::WorkflowPackage::CanonicalJSON.generate("setup" => "pending")
      File.write(File.join(module_dir, "selection.json"), old_selection)
      File.write(File.join(module_dir, "runtime", "hooks.json"), old_hooks)
      File.write(File.join(module_dir, "runtime", "setup-outbox.json"), old_setup)
      candidate = File.join(module_dir, "generations", "a" * 40)
      FileUtils.mkdir_p(candidate)
      transaction = Hive::ModulePackage::Transaction.new(module_dir)
      transaction.begin!(candidate_path: candidate, candidate_created: true)
      transaction.provisional!(
        selection_bytes: Hive::WorkflowPackage::CanonicalJSON.generate("new" => true),
        hooks_bytes: Hive::WorkflowPackage::CanonicalJSON.generate("hooks" => { "run" => true })
      )

      assert Hive::ModulePackage::Transaction.new(module_dir).reconcile!
      assert_equal old_selection, File.read(File.join(module_dir, "selection.json"))
      assert_equal old_hooks, File.read(File.join(module_dir, "runtime", "hooks.json"))
      assert_equal old_setup, File.read(File.join(module_dir, "runtime", "setup-outbox.json"))
      refute File.exist?(candidate)
      refute File.exist?(File.join(module_dir, "activation.json"))
    end
  end

  def test_reconcile_clears_committed_state_and_rejects_malformed_journals
    with_tmp_dir do |root|
      transaction = Hive::ModulePackage::Transaction.new(File.join(root, "modules", "demo"))
      FileUtils.mkdir_p(File.dirname(transaction.journal_path))
      File.write(
        transaction.journal_path,
        Hive::WorkflowPackage::CanonicalJSON.generate("schema_version" => 1, "phase" => "committed")
      )
      FileUtils.mkdir_p(File.dirname(transaction.barrier_path))
      File.write(transaction.barrier_path, "barrier")

      assert transaction.reconcile!
      refute File.exist?(transaction.journal_path)
      refute File.exist?(transaction.barrier_path)

      File.write(transaction.journal_path, JSON.pretty_generate("schema_version" => 1, "phase" => "prepared"))
      assert_raises(Hive::ConfigError) { transaction.reconcile! }
      File.write(transaction.journal_path, "{bad")
      assert_raises(Hive::ConfigError) { transaction.reconcile! }
    end
  end

  def test_rollback_rejects_a_candidate_outside_generation_storage
    with_tmp_dir do |root|
      module_dir = File.join(root, "modules", "demo")
      candidate = File.join(root, "escaped")
      FileUtils.mkdir_p(candidate)
      transaction = Hive::ModulePackage::Transaction.new(module_dir)
      transaction.begin!(candidate_path: candidate, candidate_created: true)

      assert_raises(Hive::ConfigError) { transaction.rollback! }
      assert File.directory?(candidate)
    end
  end
end
