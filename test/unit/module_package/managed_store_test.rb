require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/managed_store"
require "hive/module_package/preview"

class ModulePackageManagedStoreTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  def test_install_update_retention_and_health_rollback
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      store = Hive::ModulePackage::ManagedStore.new(state)
      first_root = File.join(root, "first")
      first_resolution, first_descriptor = write_module_package(first_root)
      first = preview_for(first_resolution, first_descriptor)
      store.apply(first, package_root: first_root, resolution: first_resolution)

      second_root = File.join(root, "second")
      second_resolution, second_descriptor = write_module_package(second_root, version: "1.1.0", commit: "b" * 40)
      second = preview_for(second_resolution, second_descriptor, store: store)
      store.apply(second, package_root: second_root, resolution: second_resolution)

      selected = store.selected("demo")
      assert_equal "b" * 40, selected.dig("active", "source_commit")
      assert_equal "a" * 40, selected.dig("previous", "source_commit")

      failed_root = File.join(root, "failed")
      failed_resolution, failed_descriptor = write_module_package(failed_root, version: "2.0.0", commit: "c" * 40)
      failed = preview_for(failed_resolution, failed_descriptor, store: store)
      error = assert_raises(Hive::ConfigError) do
        store.apply(failed, package_root: failed_root, resolution: failed_resolution,
                           health_check: ->(_path, _configuration) { raise "unsafe stderr secret=abc" })
      end
      assert_match(/activation health check failed/, error.message)
      assert_equal "b" * 40, store.selected("demo").dig("active", "source_commit")
      refute File.exist?(store.generation_path("demo", "c" * 40))
      diagnostic = JSON.parse(File.read(store.failed_activation_path("demo")))
      refute_includes JSON.generate(diagnostic), "secret=abc"
      assert_equal %w[aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb],
                   store.generation_commits("demo").sort
    end
  end

  def test_disable_reenable_and_uninstall_preserve_history_and_advance_watermark
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      store.apply(preview_for(resolution, descriptor), package_root: package, resolution: resolution)
      old_watermark = store.selected("demo").fetch("high_water_at")

      store.disable("demo", now: Time.utc(2026, 7, 22, 1))
      refute store.selected("demo").fetch("enabled")
      store.enable("demo", now: Time.utc(2026, 7, 22, 2))
      assert store.selected("demo").fetch("enabled")
      refute_equal old_watermark, store.selected("demo").fetch("high_water_at")
      store.uninstall("demo", now: Time.utc(2026, 7, 22, 3))
      selected = store.selected("demo", include_tombstone: true)
      refute selected.fetch("installed")
      refute selected.fetch("enabled")
      assert File.directory?(store.runtime_path("demo"))
    end
  end

  def test_projects_have_independent_module_state
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      one = Hive::ModulePackage::ManagedStore.new(File.join(root, "one", ".hive-state"))
      two = Hive::ModulePackage::ManagedStore.new(File.join(root, "two", ".hive-state"))
      one.apply(preview_for(resolution, descriptor), package_root: package, resolution: resolution)

      assert one.selected("demo")
      assert_nil two.selected("demo")
    end
  end

  def test_selection_snapshot_is_one_deeply_immutable_shared_lock_view
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(
        File.join(root, ".hive-state")
      )
      store.apply(
        preview_for(resolution, descriptor),
        package_root: package,
        resolution: resolution
      )

      yielded = store.with_selection_snapshot(
        %w[demo missing],
        include_tombstones: true
      ) do |snapshot|
        assert snapshot.frozen?
        assert snapshot.fetch("demo").frozen?
        assert snapshot.dig("demo", "active").frozen?
        assert_nil snapshot.fetch("missing")
        snapshot
      end
      assert_equal(
        store.inspect_selection("demo"),
        yielded.fetch("demo")
      )
      assert_raises(FrozenError) do
        yielded.fetch("demo").fetch("active")["version"] =
          "changed"
      end
    end
  end

  def test_selection_snapshot_validates_active_generation_bytes_before_yield
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(
        File.join(root, ".hive-state")
      )
      store.apply(
        preview_for(resolution, descriptor),
        package_root: package,
        resolution: resolution
      )
      payload = File.join(
        store.generation_path("demo", resolution.source_commit),
        "README.md"
      )
      File.chmod(0o644, payload)
      File.binwrite(payload, "# tampered\n")
      yielded = false

      error = assert_raises(Hive::ConfigError) do
        store.with_selection_snapshot([ "demo" ]) do
          yielded = true
        end
      end

      refute yielded
      assert_match(/payload hash|active generation/, error.message)
    end
  end

  def test_selection_snapshot_rejects_missing_active_generation_before_yield
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(
        File.join(root, ".hive-state")
      )
      store.apply(
        preview_for(resolution, descriptor),
        package_root: package,
        resolution: resolution
      )
      generation =
        store.generation_path("demo", resolution.source_commit)
      FileUtils.chmod_R(0o700, generation)
      FileUtils.rm_rf(generation)
      yielded = false

      error = assert_raises(Hive::ConfigError) do
        store.with_selection_snapshot([ "demo" ]) do
          yielded = true
        end
      end

      refute yielded
      assert_match(/manifest|active generation/, error.message)
    end
  end

  def test_selection_snapshot_binds_configuration_generation_to_active_selection
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(
        File.join(root, ".hive-state")
      )
      first_root = File.join(root, "first")
      first_resolution, first_descriptor =
        write_module_package(first_root)
      store.apply(
        preview_for(first_resolution, first_descriptor),
        package_root: first_root,
        resolution: first_resolution
      )
      second_root = File.join(root, "second")
      second_resolution, second_descriptor = write_module_package(
        second_root,
        version: "1.1.0",
        commit: "b" * 40
      )
      store.apply(
        preview_for(
          second_resolution,
          second_descriptor,
          store: store
        ),
        package_root: second_root,
        resolution: second_resolution
      )
      selection = store.selected("demo", include_tombstone: true)
      selection.fetch("active")["configuration_digest"] =
        selection.dig("previous", "configuration_digest")
      selection_path =
        File.join(store.modules_dir, "demo", "selection.json")
      File.binwrite(
        selection_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(selection)
      )
      yielded = false

      error = assert_raises(Hive::ConfigError) do
        store.with_selection_snapshot([ "demo" ]) do
          yielded = true
        end
      end

      refute yielded
      assert_match(
        /configuration generation.*active selection/,
        error.message
      )
    end
  end

  def test_failpoint_restores_selection_and_removes_candidate
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))

      assert_raises(RuntimeError) do
        store.apply(
          preview_for(resolution, descriptor), package_root: package, resolution: resolution,
          failpoint: ->(phase) { raise "crash" if phase == :pointer_provisional }
        )
      end

      assert_nil store.selected("demo", include_tombstone: true)
      refute File.exist?(store.generation_path("demo", resolution.source_commit))
    end
  end

  def test_migration_rollback_atomically_restores_previous_generation_and_hooks
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      first_root = File.join(root, "first")
      first_resolution, first_descriptor = write_module_package(first_root)
      store.apply(preview_for(first_resolution, first_descriptor), package_root: first_root, resolution: first_resolution)
      second_root = File.join(root, "second")
      second_resolution, second_descriptor = write_module_package(
        second_root, version: "1.1.0", commit: "b" * 40
      )
      store.apply(
        preview_for(second_resolution, second_descriptor, store: store),
        package_root: second_root, resolution: second_resolution
      )
      expected = store.selected("demo").fetch("active")

      restored = store.restore_previous(
        "demo", expected_active: expected, now: Time.utc(2026, 7, 22, 12)
      )

      assert_equal "a" * 40, restored.dig("active", "source_commit")
      assert_equal "b" * 40, restored.dig("previous", "source_commit")
      assert_equal restored, store.selected("demo")
      hooks = store.inspect_hooks("demo")
      assert_equal restored.dig("active", "configuration_digest"), hooks.fetch("configuration_digest")
      assert_raises(Hive::ConfigError) do
        store.restore_previous("demo", expected_active: expected)
      end
    end
  end

  def test_pruning_fails_closed_until_nonterminal_run_has_a_complete_snapshot
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      first_root = File.join(root, "first")
      first_resolution, first_descriptor = write_module_package(first_root)
      store.apply(preview_for(first_resolution, first_descriptor), package_root: first_root, resolution: first_resolution)
      second_root = File.join(root, "second")
      second_resolution, second_descriptor = write_module_package(second_root, version: "1.1.0", commit: "b" * 40)
      store.apply(preview_for(second_resolution, second_descriptor, store: store), package_root: second_root, resolution: second_resolution)
      runs = File.join(store.runtime_path("demo"), "runs")
      FileUtils.mkdir_p(runs)
      run_path = File.join(runs, "run-1.json")
      File.write(run_path, JSON.generate("status" => "running", "source_commit" => "a" * 40))
      third_root = File.join(root, "third")
      third_resolution, third_descriptor = write_module_package(third_root, version: "1.2.0", commit: "c" * 40)

      assert_raises(Hive::ConfigError) do
        store.apply(preview_for(third_resolution, third_descriptor, store: store),
                    package_root: third_root, resolution: third_resolution)
      end
      assert_equal "b" * 40, store.selected("demo").dig("active", "source_commit")

      File.write(run_path, JSON.generate(
        "status" => "running", "source_commit" => "a" * 40,
        "execution_snapshot" => {
          "schema_version" => 1,
          "descriptor" => {
            "id" => "run", "target" => { "kind" => "entrypoint", "id" => "demo.run" }
          },
          "configuration" => { "mode" => "safe" },
          "grants" => { "filesystem_read" => [ "repository" ] },
          "subject" => {
            "kind" => "module_hook", "project_id" => "project-1",
            "module" => "demo", "hook" => "run",
            "event_id" => "evt-1", "occurrence_id" => "evt-1",
            "event_name" => "task.completed", "module_generation" => "a" * 40,
            "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
          },
          "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "ownership_generation" => "1:#{'a' * 40}", "task_input_epoch" => 1
        }
      ))
      store.apply(preview_for(third_resolution, third_descriptor, store: store),
                  package_root: third_root, resolution: third_resolution)

      assert_equal %w[bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc],
                   store.generation_commits("demo").sort
    end
  end

  def test_health_rejection_existing_generation_and_commit_rollback_are_atomic
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = preview_for(resolution, descriptor)

      assert_raises(Hive::ConfigError) do
        store.apply(
          preview, package_root: package, resolution: resolution,
          health_check: ->(_path, _configuration) { false }
        )
      end
      assert_nil store.selected("demo", include_tombstone: true)

      store.apply(preview, package_root: package, resolution: resolution)
      assert_equal store.generation_path("demo", resolution.source_commit),
                   store.send(:place_generation_unlocked, package, resolution)

      before = store.selected("demo")
      assert_raises(RuntimeError) do
        store.disable("demo", commit: -> { raise "commit failed" })
      end
      assert_equal before, store.selected("demo")
    end
  end

  def test_successful_commit_callback_runs_while_activation_recovery_is_live
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      journal = File.join(store.modules_dir, "demo", "activation.json")
      barrier = File.join(store.runtime_path("demo"), "activation-barrier.json")

      store.apply(
        preview_for(resolution, descriptor), package_root: package, resolution: resolution,
        commit: lambda do
          assert File.exist?(journal)
          assert File.exist?(barrier)
        end
      )
      assert store.selected("demo")
      refute File.exist?(journal)
      refute File.exist?(barrier)
    end
  end

  def test_post_commit_cleanup_failure_is_warning_only
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      store.define_singleton_method(:cleanup_generations_unlocked!) do |*_args|
        raise Errno::EIO, "unsafe cleanup detail"
      end

      _out, error = capture_io do
        selection = store.apply(
          preview_for(resolution, descriptor), package_root: package, resolution: resolution
        )
        assert_equal resolution.source_commit, selection.dig("active", "source_commit")
      end

      assert_equal resolution.source_commit, store.selected("demo").dig("active", "source_commit")
      assert_includes error, "post-commit activation cleanup failed"
      refute_includes error, "unsafe cleanup detail"
    end
  end

  def test_failed_third_generation_commit_preserves_rollback_generation
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      packages = %w[first second third].each_with_index.map do |name, index|
        package = File.join(root, name)
        resolution, descriptor = write_module_package(
          package, version: "1.#{index}.0", commit: (index + 10).to_s(16) * 40
        )
        [ package, resolution, descriptor ]
      end
      packages.first(2).each do |package, resolution, descriptor|
        store.apply(
          preview_for(resolution, descriptor, store: store),
          package_root: package, resolution: resolution
        )
      end
      before = store.selected("demo")
      old_previous = before.dig("previous", "source_commit")

      package, resolution, descriptor = packages.fetch(2)
      assert_raises(RuntimeError) do
        store.apply(
          preview_for(resolution, descriptor, store: store),
          package_root: package, resolution: resolution,
          commit: -> { raise "commit failed" }
        )
      end

      assert_equal before, store.selected("demo")
      assert File.directory?(store.generation_path("demo", old_previous))
    end
  end

  def test_configuration_only_update_retains_immediate_rollback_target
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      store.apply(
        preview_for(resolution, descriptor), package_root: package, resolution: resolution
      )
      current = store.selected("demo")
      current_configuration = store.configuration(
        "demo", current.dig("active", "configuration_digest")
      )
      update = Hive::ModulePackage::Preview.build(
        operation: "update", descriptor: descriptor, generation: resolution,
        current: current, current_configuration: current_configuration,
        settings: { "mode" => "fast" }, hooks: {},
        grants: exact_grants(descriptor)
      )

      store.apply(update, package_root: package, resolution: resolution)
      selected = store.selected("demo")

      assert_equal current.fetch("active"), selected.fetch("previous")
      refute_equal selected.dig("active", "configuration_digest"),
                   selected.dig("previous", "configuration_digest")
    end
  end

  def test_reinstall_and_changed_binding_start_at_current_high_water
    with_tmp_dir do |root|
      first_root = File.join(root, "first")
      first_resolution, first_descriptor = write_module_package(first_root)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      store.apply(
        preview_for(first_resolution, first_descriptor),
        package_root: first_root, resolution: first_resolution,
        now: Time.utc(2026, 7, 22, 10)
      )
      hooks_path = File.join(store.runtime_path("demo"), "hooks.json")
      hooks = JSON.parse(File.binread(hooks_path))
      hooks.fetch("hooks").fetch("schedule")["cursor"] = "evt-old"
      File.write(hooks_path, Hive::WorkflowPackage::CanonicalJSON.generate(hooks))

      changed_hooks = [
        {
          "id" => "schedule", "target" => { "kind" => "entrypoint", "id" => "demo.changed" },
          "default_enabled" => true, "schedules" => [ "0 * * * *" ],
          "events" => [], "concurrency" => "drop"
        }
      ]
      second_root = File.join(root, "second")
      second_resolution, second_descriptor = write_module_package(
        second_root, version: "1.1.0", commit: "b" * 40, hooks: changed_hooks
      )
      current = store.selected("demo")
      current_configuration = store.configuration(
        "demo", current.dig("active", "configuration_digest")
      )
      update = Hive::ModulePackage::Preview.build(
        operation: "update", descriptor: second_descriptor, generation: second_resolution,
        current: current, current_configuration: current_configuration,
        settings: {}, hooks: {}, grants: exact_grants(second_descriptor),
        now: Time.utc(2026, 7, 22, 11)
      )
      store.apply(
        update, package_root: second_root, resolution: second_resolution,
        now: Time.utc(2026, 7, 22, 11)
      )
      assert_equal "watermark:2026-07-22T11:00:00.000000Z",
                   store.inspect_hooks("demo").dig("hooks", "schedule", "cursor")

      store.uninstall("demo", now: Time.utc(2026, 7, 22, 12))
      tombstone = store.selected("demo", include_tombstone: true)
      tombstone_configuration = store.configuration(
        "demo", tombstone.dig("previous", "configuration_digest")
      )
      reinstall = Hive::ModulePackage::Preview.build(
        operation: "update", descriptor: second_descriptor, generation: second_resolution,
        current: tombstone, current_configuration: tombstone_configuration,
        settings: {}, hooks: {}, grants: exact_grants(second_descriptor),
        now: Time.utc(2026, 7, 22, 13)
      )
      store.apply(
        reinstall, package_root: second_root, resolution: second_resolution,
        now: Time.utc(2026, 7, 22, 13)
      )
      assert_equal "2026-07-22T13:00:00.000000Z",
                   store.selected("demo").fetch("high_water_at")
    end
  end

  def test_inspection_rejects_corrupt_state_and_returns_empty_missing_hooks
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      assert_equal({}, store.inspect_hooks("demo").fetch("hooks"))
      assert_raises(Hive::ConfigError) { store.configuration("demo", "a" * 64) }

      hooks_path = File.join(store.runtime_path("demo"), "hooks.json")
      FileUtils.mkdir_p(File.dirname(hooks_path))
      File.write(hooks_path, JSON.pretty_generate("schema_version" => 1, "hooks" => {}))
      assert_raises(Hive::ConfigError) { store.inspect_hooks("demo") }
      File.write(hooks_path, "{bad")
      assert_raises(Hive::ConfigError) { store.inspect_hooks("demo") }
      assert_equal({}, store.send(:read_hooks, "missing"))

      FileUtils.mkdir_p(store.modules_dir)
      with_replaced_singleton_method(Dir, :children, ->(_path) { raise Errno::EACCES, "blocked" }) do
        assert_raises(Hive::ConfigError) { store.module_names }
      end
    end
  end

  def test_reconcile_and_cleanup_fail_closed_on_corrupt_runtime_evidence
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      module_dir = File.join(store.modules_dir, "demo")
      candidate = File.join(module_dir, "generations", "a" * 40)
      FileUtils.mkdir_p(candidate)
      transaction = Hive::ModulePackage::Transaction.new(module_dir)
      transaction.begin!(candidate_path: candidate, candidate_created: true)

      assert store.reconcile!
      refute File.exist?(transaction.journal_path)

      runs = File.join(store.runtime_path("demo"), "runs")
      FileUtils.mkdir_p(runs)
      File.write(File.join(runs, "broken.json"), "{bad")
      assert_raises(Hive::ConfigError) { store.send(:run_generation_references, "demo") }
    end
  end

  def test_diagnostic_cleanup_io_failures_are_bounded
    with_tmp_dir do |root|
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*_args, **_options) { raise Errno::EACCES, "blocked" }
      ) do
        assert_nil store.send(:write_failed_activation, "demo", RuntimeError.new("secret"), Time.now.utc)
      end

      path = store.failed_activation_path("demo")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "diagnostic")
      with_replaced_singleton_method(FileUtils, :rm_f, ->(_path) { raise Errno::EACCES, "blocked" }) do
        assert_nil store.send(:clear_failed_activation, "demo")
      end
    end
  end

  def test_rejects_malformed_resolution_and_selection_identities
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = preview_for(resolution, descriptor)

      assert_raises(Hive::ConfigError) do
        store.apply(preview, package_root: package, resolution: resolution.with(version: "latest"))
      end
      assert_raises(Hive::ConfigError) { store.generation_path("demo", "short") }

      store.apply(preview, package_root: package, resolution: resolution)
      selection_path = File.join(store.modules_dir, "demo", "selection.json")
      current = store.selected("demo")
      File.write(selection_path, Hive::WorkflowPackage::CanonicalJSON.generate("schema_version" => 1))
      assert_raises(Hive::ConfigError) { store.inspect_selection("demo") }

      invalid_generation = JSON.parse(JSON.generate(current))
      invalid_generation.fetch("active")["version"] = "latest"
      File.write(selection_path, Hive::WorkflowPackage::CanonicalJSON.generate(invalid_generation))
      assert_raises(Hive::ConfigError) { store.inspect_selection("demo") }
    end
  end

  def test_install_setup_outbox_is_activation_atomic_and_generation_scoped
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "setup", "target" => { "kind" => "entrypoint", "id" => "demo.setup" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "project.registered" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, hooks: hooks)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "setup" => true }, grants: exact_grants(descriptor),
        now: Time.utc(2026, 7, 22, 10)
      )

      store.apply(
        preview, package_root: package, resolution: resolution,
        setup_context: { project_id: "project-1", project: "demo" },
        now: Time.utc(2026, 7, 22, 10)
      )

      intent = store.inspect_setup_outbox("demo")
      assert_equal [ "setup" ], intent.fetch("hooks")
      assert_equal resolution.source_commit, intent.fetch("source_commit")
      assert_equal preview.digest, intent.fetch("receipt_digest")
      yielded = nil
      promoted = store.promote_setup_outbox("demo") do |pending|
        yielded = pending
        :persisted
      end
      assert_equal intent, yielded
      assert_equal :published, promoted.fetch(:status)
      assert_equal :persisted, promoted.fetch(:result)
      assert_nil store.inspect_setup_outbox("demo")
      assert_equal :none, store.promote_setup_outbox("demo") { flunk }.fetch(:status)
    end
  end

  def test_setup_outbox_rejects_missing_identity_and_malformed_evidence
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "setup",
          "target" => { "kind" => "entrypoint", "id" => "demo.setup" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "project.registered" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, hooks: hooks)
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "setup" => true }, grants: exact_grants(descriptor)
      )

      invalid_store = Hive::ModulePackage::ManagedStore.new(
        File.join(root, "invalid", ".hive-state")
      )
      assert_raises(Hive::ConfigError) do
        invalid_store.apply(
          preview, package_root: package, resolution: resolution,
          setup_context: { project_id: "", project: "demo" }
        )
      end

      store = Hive::ModulePackage::ManagedStore.new(
        File.join(root, "valid", ".hive-state")
      )
      store.apply(
        preview, package_root: package, resolution: resolution,
        setup_context: { project_id: "project-1", project: "demo" }
      )
      path = store.send(:setup_outbox_path, "demo")
      File.binwrite(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          "schema_version" => 1, "module" => "demo"
        )
      )
      assert_raises(Hive::ConfigError) { store.inspect_setup_outbox("demo") }

      File.write(path, "{")
      assert_raises(Hive::ConfigError) { store.inspect_setup_outbox("demo") }
    end
  end

  def test_disable_discards_pending_setup_and_failed_update_restores_it
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "setup", "target" => { "kind" => "entrypoint", "id" => "demo.setup" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "project.registered" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, hooks: hooks)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "setup" => true }, grants: exact_grants(descriptor),
        now: Time.utc(2026, 7, 22, 10)
      )
      store.apply(
        preview, package_root: package, resolution: resolution,
        setup_context: { project_id: "project-1", project: "demo" },
        now: Time.utc(2026, 7, 22, 10)
      )
      original = store.inspect_setup_outbox("demo")

      update_root = File.join(root, "update")
      update_resolution, update_descriptor = write_module_package(
        update_root, hooks: hooks, version: "1.1.0", commit: "b" * 40
      )
      current = store.selected("demo")
      current_configuration = store.configuration(
        "demo", current.dig("active", "configuration_digest")
      )
      update_preview = Hive::ModulePackage::Preview.build(
        operation: "update", descriptor: update_descriptor, generation: update_resolution,
        current: current, current_configuration: current_configuration,
        settings: {}, hooks: {}, grants: exact_grants(update_descriptor)
      )
      assert_raises(Hive::ConfigError) do
        store.apply(
          update_preview, package_root: update_root, resolution: update_resolution,
          health_check: ->(*) { false }
        )
      end
      assert_equal original, store.inspect_setup_outbox("demo")

      store.disable("demo")
      stale = store.promote_setup_outbox("demo") { flunk }
      assert_equal :stale, stale.fetch(:status)
      assert_nil store.inspect_setup_outbox("demo")
    end
  end

  private

  def preview_for(resolution, descriptor, store: nil)
    current = store&.selected("demo", include_tombstone: true)
    current_configuration = if current&.dig("active", "configuration_digest")
                              store.configuration("demo", current.dig("active", "configuration_digest"))
    end
    Hive::ModulePackage::Preview.build(
      operation: current ? "update" : "install", descriptor: descriptor, generation: resolution,
      current: current, current_configuration: current_configuration,
      settings: current ? {} : { "mode" => "safe", "api_token" => nil },
      hooks: current ? {} : { "schedule" => true }, grants: exact_grants(descriptor),
      now: Time.now.utc
    )
  end
end
