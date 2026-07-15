require "test_helper"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/registry_client"
require "hive/task"
require "hive/workflows/loader"

class WorkflowPackageManagedStoreTest < Minitest::Test
  include HiveTestHelper

  def test_places_activates_and_verifies_immutable_generation
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)

      generation = store.place_generation(package, resolution)
      store.activate(resolution)

      assert_equal generation, store.generation_path("demo", resolution.source_commit)
      assert_equal resolution.source_commit, store.selected("demo").fetch("source_commit")
      assert_equal :demo, store.workflow("demo", resolution.source_commit, resolution.manifest_digest).id
      assert store.verify_generation("demo", resolution.source_commit, resolution.manifest_digest).valid?
    end
  end

  def test_tampering_fails_integrity_and_cleanup_retains_task_pins
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      package = File.join(dir, "package")
      old = write_package(package, "a" * 40)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      store.place_generation(package, old)
      store.activate(old)

      task = File.join(hive_state, "stages", "1-inbox", "task-260715-aaaa")
      Hive::TaskMeta.write(task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
                          workflow_commit: old.source_commit, workflow_manifest_digest: old.manifest_digest)
      store.remove_selection("demo")
      assert_includes store.cleanup_unreferenced("demo"), old.source_commit, "pinned generation is reported retained"
      assert File.directory?(store.generation_path("demo", old.source_commit))

      File.write(File.join(store.generation_path("demo", old.source_commit), "README.md"), "tampered\n")
      refute store.verify_generation("demo", old.source_commit, old.manifest_digest).valid?
    end
  end

  def test_loader_discovers_selection_and_task_pin_resolves_after_removal
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      store.place_generation(package, resolution)
      store.activate(resolution)

      loaded = Hive::Workflows::Loader.load_dir(store.workflows_dir)
      assert_equal :demo, loaded.fetch(:demo).id

      task = File.join(hive_state, "stages", "1-inbox", "managed-260715-aaaa")
      Hive::TaskMeta.write(task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
                          workflow_commit: resolution.source_commit,
                          workflow_manifest_digest: resolution.manifest_digest)
      store.remove_selection("demo")

      resolved = Hive::Task.new(task)
      assert_equal :demo, resolved.workflow.id
      assert_equal resolution.source_commit, resolved.workflow_commit
      assert resolved.managed_workflow?
    end
  end

  private

  def write_package(root, commit)
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo\n")
    File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
    File.write(File.join(root, "instructions", "work.md"), "Read only.\n")
    File.write(File.join(root, "workflow.yml"), <<~YAML)
      id: demo
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: work
          kind: agent
          state_file: work.md
          advance_verb: work
          instruction: instructions/work.md
          permissions: read-only
        - name: done
          kind: terminal
          state_file: done.md
          advance_verb: done
    YAML
    permissions = {
      "tools" => [ "Read" ], "deny" => [ "Bash" ], "directories" => [],
      "commands" => [], "domains" => [], "credentials" => []
    }
    manifest = Hive::WorkflowPackage::Manifest.build(
      root,
      metadata: { "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
                  "author" => { "name" => "Test" }, "dependencies" => {}, "permissions" => permissions }
    )
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.0.0", source_commit: commit, catalog_commit: "b" * 40,
      manifest_digest: manifest.digest, summary: "Demo", permissions: permissions
    )
  end
end
