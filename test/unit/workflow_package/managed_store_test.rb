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

  def test_activation_rechecks_the_selected_baseline
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      old = write_package(File.join(dir, "old"), "a" * 40)
      candidate = write_package(File.join(dir, "candidate"), "c" * 40)
      store.place_generation(File.join(dir, "old"), old)
      store.place_generation(File.join(dir, "candidate"), candidate)
      store.activate(old)
      stale = store.selected("demo").merge("manifest_digest" => "0" * 64)

      assert_raises(Hive::ConcurrentRunError) do
        store.activate(candidate, expected_current: stale)
      end
    end
  end

  def test_malformed_locks_are_visible_directly_and_ignored_by_selection_enumeration
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      path = store.lock_path("demo")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not-json")

      assert_raises(Hive::ConfigError) { store.selected("demo") }
      assert_empty store.selections

      malformed = { "schema_version" => 1, "name" => "demo" }
      File.write(path, JSON.generate(malformed))
      assert_raises(Hive::ConfigError) { store.selected("demo") }

      valid_shape = {
        "schema_version" => 1, "name" => "demo", "version" => "1.0.0",
        "catalog_commit" => "b" * 40, "source_commit" => "a" * 40,
        "manifest_digest" => "bad", "summary" => "Demo", "permissions" => {}
      }
      File.write(path, JSON.generate(valid_shape))
      assert_raises(Hive::ConfigError) { store.selected("demo") }
    end
  end

  def test_store_reconciles_a_pending_pointer_journal
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      lock = store.lock_path("demo")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{\"new\":true}\n")
      Hive::WorkflowPackage::TransactionJournal.new(store.workflows_dir).write(
        "schema_version" => 1, "phase" => "pointer_written", "lock_path" => lock,
        "old_lock" => "{\"old\":true}\n", "new_lock" => "{\"new\":true}\n"
      )

      assert store.reconcile!
      assert_equal "{\"old\":true}\n", File.read(lock)
    end
  end

  def test_selection_reads_wait_for_live_workflow_transactions
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store.place_generation(package, resolution)
      store.activate(resolution)
      entered = Queue.new
      release = Queue.new
      holder = Thread.new do
        Hive::WorkflowPackage::MutationLock.with_lock(store.workflows_dir) do
          entered << true
          release.pop
        end
      end
      entered.pop

      reader = Thread.new { store.selected("demo") }
      refute reader.join(0.05), "selection read must not reconcile a live transaction"
      release << true
      holder.join
      reader.join
      assert_equal resolution.source_commit, reader.value.fetch("source_commit")
    end
  end

  def test_cleanup_waits_for_task_moves_and_fails_closed_on_invalid_metadata
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store.place_generation(package, resolution)
      store.activate(resolution)
      task = File.join(hive_state, "stages", "1-inbox", "managed-260715-aaaa")
      Hive::TaskMeta.write(
        task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
        workflow_commit: resolution.source_commit,
        workflow_manifest_digest: resolution.manifest_digest
      )
      store.remove_selection("demo")

      started = Queue.new
      cleanup = nil
      Hive::WorkflowPackage::MutationLock.with_lock(store.workflows_dir, shared: true) do
        cleanup = Thread.new do
          started << true
          store.cleanup_unreferenced("demo")
        end
        started.pop
        refute cleanup.join(0.05), "cleanup must wait while a task path can move"
        destination = File.join(hive_state, "stages", "2-work", File.basename(task))
        FileUtils.mkdir_p(File.dirname(destination))
        File.rename(task, destination)
        task = destination
      end
      cleanup.join
      assert_includes cleanup.value, resolution.source_commit
      assert File.directory?(store.generation_path("demo", resolution.source_commit))

      File.write(Hive::TaskMeta.path(task), "workflow: [invalid\n")
      assert_raises(Hive::ConfigError) { store.cleanup_unreferenced("demo") }
      assert File.directory?(store.generation_path("demo", resolution.source_commit))
    end
  end

  def test_store_rejects_invalid_names_commits_and_resolution_provenance
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      assert_raises(Hive::ConfigError) { store.lock_path("Bad Name") }
      assert_raises(Hive::ConfigError) { store.generation_path("demo", "short") }

      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40).with(catalog_commit: "short")
      assert_raises(Hive::ConfigError) { store.place_generation(package, resolution) }
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
      source_revision: commit, manifest_digest: manifest.digest, hive_min_version: "0.4.3",
      summary: "Demo", permissions: permissions
    )
  end
end
