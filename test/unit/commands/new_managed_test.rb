require "test_helper"
require "hive/commands/new"
require "hive/workflow_package/canonical_json"

class NewManagedWorkflowTest < Minitest::Test
  include HiveTestHelper

  def test_task_creation_rechecks_the_managed_selection_under_the_shared_lock
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      path = store.lock_path("demo")
      FileUtils.mkdir_p(File.dirname(path))
      current = {
        "schema_version" => 1, "name" => "demo", "version" => "1.1.0",
        "catalog_commit" => "b" * 40, "source_commit" => "c" * 40,
        "manifest_digest" => "d" * 64, "summary" => "Demo", "permissions" => {}
      }
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(current))
      baseline = current.merge("source_commit" => "a" * 40)
      command = Hive::Commands::New.new("project", "idea")
      workflow = Struct.new(:id).new(:demo)

      assert_raises(Hive::ConcurrentRunError) do
        command.send(
          :write_task_meta, File.join(dir, "task"), id: 1, slug: "task", depends_on: nil,
          workflow: workflow, workflow_info: { managed: baseline, pin: true }, hive_state: hive_state
        )
      end
    end
  end
end
