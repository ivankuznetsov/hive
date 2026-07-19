require "test_helper"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/canonical_yaml"
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
      assert_equal 0o444, File.stat(File.join(generation, "README.md")).mode & 0o777
      assert_equal 0o555, File.stat(generation).mode & 0o777
    end
  end

  def test_generation_is_hardened_before_publication_and_retry_succeeds
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40, executable: true, registry: true)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      observed_modes = nil
      original_rename = File.method(:rename)
      interrupting_rename = lambda do |source, destination|
        if File.basename(source).start_with?(".staging-")
          observed_modes = {
            root: File.stat(source).mode & 0o777,
            directory: File.stat(File.join(source, "instructions")).mode & 0o777,
            readme: File.stat(File.join(source, "README.md")).mode & 0o777,
            executable: File.stat(File.join(source, "instructions", "work.md")).mode & 0o777
          }
          raise Errno::EIO, "synthetic publication interruption"
        end

        original_rename.call(source, destination)
      end

      assert_raises(Errno::EIO) do
        with_replaced_singleton_method(File, :rename, interrupting_rename) do
          store.place_generation(package, resolution)
        end
      end
      assert_equal({ root: 0o555, directory: 0o555, readme: 0o444, executable: 0o555 }, observed_modes)
      assert_empty Dir.glob(File.join(store.workflows_dir, "**", ".staging-*"))

      generation = store.place_generation(package, resolution)
      assert File.directory?(generation)
    end
  end

  def test_reusing_a_generation_repairs_exact_modes_and_preserves_executables
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40, executable: true, registry: true)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      generation = store.place_generation(package, resolution)
      instructions = File.join(generation, "instructions")
      readme = File.join(generation, "README.md")
      executable = File.join(instructions, "work.md")

      File.chmod(0o755, generation)
      File.chmod(0o700, instructions)
      File.chmod(0o644, readme)
      File.chmod(0o444, executable)

      assert_equal generation, store.place_generation(package, resolution)
      assert_equal 0o555, File.stat(generation).mode & 0o777
      assert_equal 0o555, File.stat(instructions).mode & 0o777
      assert_equal 0o444, File.stat(readme).mode & 0o777
      assert_equal 0o555, File.stat(executable).mode & 0o777
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

      readme = File.join(store.generation_path("demo", old.source_commit), "README.md")
      File.chmod(0o644, readme)
      File.write(readme, "tampered\n")
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

  def test_task_pins_configuration_while_selected_mapping_changes
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      store.place_generation(package, resolution)
      raw = store.workflow("demo", resolution.source_commit, resolution.manifest_digest)
      generation = {
        "name" => "demo", "source_commit" => resolution.source_commit,
        "manifest_digest" => resolution.manifest_digest
      }
      old_configuration = Hive::WorkflowPackage::Configuration.build(
        raw, generation: generation,
        overrides: { "stages.work" => { "agent" => "codex", "model" => "gpt-5.6-sol" } }
      )
      store.activate(resolution, configuration: old_configuration)

      task = File.join(hive_state, "stages", "1-inbox", "configured-260718-aaaa")
      Hive::TaskMeta.write(
        task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
        workflow_commit: resolution.source_commit, workflow_manifest_digest: resolution.manifest_digest,
        workflow_configuration_digest: old_configuration.digest
      )
      new_configuration = Hive::WorkflowPackage::Configuration.build(raw, generation: generation)
      store.activate(resolution, configuration: new_configuration, expected_current: store.selected("demo"))

      resolved = Hive::Task.new(task)
      assert_equal old_configuration.digest, resolved.workflow_configuration_digest
      assert_equal "codex", resolved.workflow.stage_named("work").agent
      assert_equal new_configuration.digest, store.selected("demo").fetch("configuration_digest")

      store.remove_selection("demo")
      store.cleanup_unreferenced("demo")
      assert File.file?(store.configuration_path("demo", old_configuration.digest))
      refute File.exist?(store.configuration_path("demo", new_configuration.digest))
    end
  end

  def test_legacy_v1_lock_and_tasks_derive_stable_configuration_without_bricking
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      store.place_generation(package, resolution)
      store.activate(resolution)
      loaded = false
      current = store.selected("demo") { loaded = true }
      refute loaded, "a current lock must not request legacy project config"
      FileUtils.rm_f(store.configuration_path("demo", current.fetch("configuration_digest")))
      legacy_lock = current.reject { |key, _value| %w[configuration_digest legacy_lock_schema].include?(key) }
                           .merge("schema_version" => 1)
      File.write(store.lock_path("demo"), Hive::WorkflowPackage::CanonicalJSON.generate(legacy_lock))

      loads = 0
      selected = store.selected("demo") do
        loads += 1
        {}
      end
      assert_equal 1, loads
      assert_equal 1, selected.fetch("legacy_lock_schema")
      assert_match(/\A[0-9a-f]{64}\z/, selected.fetch("configuration_digest"))
      assert_equal "claude", Hive::Workflows::Loader.load_dir(store.workflows_dir).fetch(:demo).stage_named("work").agent

      old_task = File.join(hive_state, "stages", "1-inbox", "legacy-260718-aaaa")
      Hive::TaskMeta.write(
        old_task, id: 1, slug: File.basename(old_task), display_name: nil, workflow: "demo",
        workflow_commit: resolution.source_commit, workflow_manifest_digest: resolution.manifest_digest
      )
      assert_equal :demo, Hive::Task.new(old_task).workflow.id

      pinned_task = File.join(hive_state, "stages", "1-inbox", "pinned-260718-bbbb")
      Hive::TaskMeta.write(
        pinned_task, id: 2, slug: File.basename(pinned_task), display_name: nil, workflow: "demo",
        workflow_commit: resolution.source_commit, workflow_manifest_digest: resolution.manifest_digest,
        workflow_configuration_digest: selected.fetch("configuration_digest")
      )
      store.remove_selection("demo")
      assert_equal "claude", Hive::Task.new(pinned_task).workflow.stage_named("work").agent
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

  def test_activation_rejects_a_stale_configuration_baseline_on_the_same_generation
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store.place_generation(package, resolution)
      store.activate(resolution)
      stale = store.selected("demo")
      workflow = store.workflow("demo", resolution.source_commit, resolution.manifest_digest)
      generation = {
        "name" => "demo", "source_commit" => resolution.source_commit,
        "manifest_digest" => resolution.manifest_digest
      }
      changed = Hive::WorkflowPackage::Configuration.build(
        workflow, generation: generation,
        overrides: { "stages.work" => { "agent" => "claude", "model" => "opus" } }
      )
      store.activate(resolution, configuration: changed, expected_current: stale)

      assert_raises(Hive::ConcurrentRunError) do
        store.activate(resolution, expected_current: stale)
      end
    end
  end

  def test_malformed_locks_are_visible_directly_and_reported_by_selection_enumeration
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      path = store.lock_path("demo")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not-json")

      assert_raises(Hive::ConfigError) { store.selected("demo") }
      selections = nil
      _out, err = capture_io { selections = store.selections }
      assert_empty selections
      assert_includes err, 'managed workflow "demo"'
      assert_includes err, "malformed"

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

  def test_selection_enumeration_reports_missing_configuration_and_keeps_healthy_sibling
    assert_invalid_configuration_isolated("unavailable") do |_store, _digest, _path|
      nil
    end
  end

  def test_selection_enumeration_reports_malformed_configuration_and_keeps_healthy_sibling
    assert_invalid_configuration_isolated("malformed") do |_store, _digest, path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not-json")
    end
  end

  def test_selection_enumeration_reports_tampered_configuration_digest_and_keeps_healthy_sibling
    assert_invalid_configuration_isolated("tampered") do |store, _digest, path|
      FileUtils.mkdir_p(File.dirname(path))
      healthy = store.selected("demo")
      FileUtils.copy_file(store.configuration_path("demo", healthy.fetch("configuration_digest")), path)
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

  def test_cleanup_fails_closed_on_incomplete_managed_task_provenance
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store.place_generation(package, resolution)
      store.activate(resolution)
      store.remove_selection("demo")
      task = File.join(hive_state, "stages", "1-inbox", "managed-260715-aaaa")
      FileUtils.mkdir_p(task)
      variants = {
        "configuration-only" => { "workflow" => "demo", "workflow_configuration_digest" => "c" * 64 },
        "commit-only" => { "workflow" => "demo", "workflow_commit" => resolution.source_commit },
        "manifest-digest-only" => { "workflow" => "demo", "workflow_manifest_digest" => resolution.manifest_digest },
        "missing-workflow" => {
          "workflow_commit" => resolution.source_commit,
          "workflow_manifest_digest" => resolution.manifest_digest
        }
      }

      variants.each do |label, metadata|
        File.write(Hive::TaskMeta.path(task), metadata.to_yaml)
        error = assert_raises(Hive::ConfigError, label) { store.cleanup_unreferenced("demo") }
        assert_includes error.message, "incomplete managed workflow provenance", label
        assert File.directory?(store.generation_path("demo", resolution.source_commit)), label
      end
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

  def test_generation_configuration_mismatches_fail_at_workflow_activation_and_lock_read
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store.place_generation(package, resolution)
      raw = store.workflow("demo", resolution.source_commit, resolution.manifest_digest)
      mismatched = Hive::WorkflowPackage::Configuration.build(
        raw,
        generation: {
          "name" => "demo", "source_commit" => "c" * 40,
          "manifest_digest" => resolution.manifest_digest
        }
      )
      store.place_configuration(mismatched)

      assert_raises(Hive::ConfigError) do
        store.workflow(
          "demo", resolution.source_commit, resolution.manifest_digest,
          configuration_digest: mismatched.digest
        )
      end
      assert_raises(Hive::ConfigError) { store.activate(resolution, configuration: mismatched) }

      store.activate(resolution)
      lock = JSON.parse(File.read(store.lock_path("demo")))
      lock["configuration_digest"] = mismatched.digest
      File.write(store.lock_path("demo"), Hive::WorkflowPackage::CanonicalJSON.generate(lock))
      assert_raises(Hive::ConfigError) { store.selected("demo") }
    end
  end

  def test_generation_cleanup_tolerates_an_entry_disappearing_during_mode_repair
    with_tmp_dir do |dir|
      root = File.join(dir, "generation")
      child = File.join(root, "child")
      FileUtils.mkdir_p(root)
      File.write(child, "payload")
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      original = File.method(:chmod)
      replacement = lambda do |mode, path|
        raise Errno::ENOENT, path if path == child

        original.call(mode, path)
      end

      with_replaced_singleton_method(File, :chmod, replacement) do
        store.send(:remove_generation_tree, root)
      end
      refute File.exist?(root)
    end
  end

  private

  def assert_invalid_configuration_isolated(expected_reason)
    with_tmp_dir do |dir|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(dir, ".hive-state"))
      package = File.join(dir, "package")
      resolution = write_package(package, "a" * 40)
      store.place_generation(package, resolution)
      store.activate(resolution)
      digest = "d" * 64
      path = store.configuration_path("broken", digest)
      yield store, digest, path
      healthy = store.selected("demo")
      broken = healthy.merge("name" => "broken", "configuration_digest" => digest)
      FileUtils.mkdir_p(File.dirname(store.lock_path("broken")))
      File.write(store.lock_path("broken"), Hive::WorkflowPackage::CanonicalJSON.generate(broken))

      selections = nil
      _out, err = capture_io { selections = store.selections }
      assert_equal [ "demo" ], selections.map { |selection| selection.fetch("name") }
      assert_equal 1, err.lines.length
      assert_includes err, 'managed workflow "broken"'
      assert_includes err, expected_reason
    end
  end

  def write_package(root, commit, executable: false, registry: false)
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo\n")
    File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
    File.write(File.join(root, "instructions", "work.md"), "Read only.\n")
    File.chmod(0o755, File.join(root, "instructions", "work.md")) if executable
    File.chmod(0o755, File.join(root, "README.md")) if registry && executable
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
          mapping_role: development
          mapping_contract: demo-work-v1
        - name: done
          kind: terminal
          state_file: done.md
          advance_verb: done
    YAML
    if registry
      permissions = {
        "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
        "filesystem_read" => %w[repository task], "filesystem_write" => [], "secrets" => []
      }
      prefix = "packages/demo/1.0.0/"
      files = %w[README.md honeycomb.yml instructions/work.md workflow.yml].to_h do |relative|
        [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(root, relative)).hexdigest ]
      end
      document = {
        "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => "1.0.0",
        "description" => "Demo", "author" => { "name" => "Test", "url" => "https://example.test/test" },
        "license" => "MIT", "hive_min_version" => "0.4.3",
        "source" => { "url" => "https://example.test/source", "revision" => commit },
        "permissions" => permissions, "files" => files,
        "x-hive" => {
          "tools" => executable ? [ { "path" => "instructions/work.md" } ] : [],
          "optional_inputs" => []
        }
      }
      document["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
      )
      File.binwrite(
        File.join(root, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
      )
      manifest_digest = document.fetch("release_sha256")
    else
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
      manifest_digest = manifest.digest
    end
    Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.0.0", source_commit: commit, catalog_commit: "b" * 40,
      source_revision: commit, manifest_digest: manifest_digest, hive_min_version: "0.4.3",
      summary: "Demo", permissions: permissions
    )
  end
end
