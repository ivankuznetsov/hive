require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/inspector"
require "json_schemer"

class ModulesStatusTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 12, 15, 0)

  def test_projects_one_redacted_status_with_next_trigger
    with_installed_module do |root, store|
      inspector = inspector(store, root, available: { "MODULE_TOKEN" => true })
      status = inspector.inspect("demo")

      assert_equal "active", status["lifecycle_state"]
      assert_equal "a" * 40, status.dig("active", "source_commit")
      assert status.dig("integrity", "configuration_valid")
      token = status.fetch("settings").find { |row| row.fetch("name") == "api_token" }
      assert_nil token.fetch("value")
      assert_equal "MODULE_TOKEN", token.fetch("binding")
      assert_equal true, token.fetch("available")
      assert_equal "2026-07-22T13:00:00.000000Z", status.fetch("hooks").first.fetch("next_trigger_at")
      refute_includes JSON.generate(status.to_h), "raw-secret-value"
      payload = {
        "schema" => "hive-module-status", "schema_version" => 1, "ok" => true,
        "modules" => [ status.to_h ]
      }
      schema = JSONSchemer.schema(Pathname(Hive::Schemas.schema_path("hive-module-status")))
      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
    end
  end

  def test_interrupted_activation_is_reported_without_reconciliation
    with_installed_module do |root, store|
      barrier = File.join(store.runtime_path("demo"), "activation-barrier.json")
      File.write(barrier, "{}")
      before = tree_digest(root)

      status = inspector(store, root).inspect("demo")

      assert_equal "activating", status["lifecycle_state"]
      assert_equal true, status.dig("integrity", "activation_fenced")
      assert_equal before, tree_digest(root)
      assert File.exist?(barrier)
    end
  end

  def test_malformed_selection_returns_bounded_corrupt_projection
    with_installed_module do |root, store|
      File.write(File.join(store.modules_dir, "demo", "selection.json"), "secret stderr\n")
      status = inspector(store, root).inspect("demo")

      assert_equal "corrupt", status["lifecycle_state"]
      assert_equal "state_corrupt", status["failure_reason"]
      refute_includes JSON.generate(status.to_h), "secret stderr"
    end
  end

  private

  def with_installed_module
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => "MODULE_TOKEN" },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      yield root, store
    end
  end

  def inspector(store, root, available: {})
    Hive::Modules::Inspector.new(
      store: store,
      attempt_store: Hive::Attempts::Store.new(root: File.join(root, "attempts"), create_directories: false),
      secret_availability: ->(name) { available.fetch(name, false) }, clock: -> { NOW }
    )
  end

  def tree_digest(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next unless File.file?(path)
      [ path.delete_prefix("#{root}/"), Digest::SHA256.file(path).hexdigest ]
    end
  end
end
