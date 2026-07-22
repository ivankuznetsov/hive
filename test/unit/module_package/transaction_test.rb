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
      File.write(File.join(module_dir, "selection.json"), old_selection)
      File.write(File.join(module_dir, "runtime", "hooks.json"), old_hooks)
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
      refute File.exist?(candidate)
      refute File.exist?(File.join(module_dir, "activation.json"))
    end
  end
end
