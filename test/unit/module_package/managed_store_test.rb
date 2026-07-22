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
          "descriptor" => { "name" => "demo" }, "configuration" => { "mode" => "safe" },
          "grants" => { "filesystem_read" => [ "repository" ] }
        }
      ))
      store.apply(preview_for(third_resolution, third_descriptor, store: store),
                  package_root: third_root, resolution: third_resolution)

      assert_equal %w[bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc],
                   store.generation_commits("demo").sort
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
