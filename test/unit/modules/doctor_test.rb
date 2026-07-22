require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/doctor"
require "hive/modules/inspector"

class ModulesDoctorTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 12, 0, 0)

  def test_reports_missing_required_binding_and_incomplete_snapshot_without_repair
    with_tmp_dir do |root|
      settings = [ { "name" => "api_token", "type" => "secret", "required" => true, "secret" => true } ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, settings: settings)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil, settings: { "api_token" => "MISSING_TOKEN" },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      run_root = File.join(store.runtime_path("demo"), "runs")
      FileUtils.mkdir_p(run_root)
      File.write(File.join(run_root, "run.json"), JSON.generate(
        "run_id" => "run", "status" => "running", "execution_snapshot" => {}
      ))
      barrier = File.join(store.runtime_path("demo"), "activation-barrier.json")
      File.write(barrier, "{}")
      inspector = Hive::Modules::Inspector.new(
        store: store,
        attempt_store: Hive::Attempts::Store.new(root: File.join(root, "attempts"), create_directories: false),
        secret_availability: ->(_name) { false }, clock: -> { NOW }
      )
      before = tree_digest(root)

      result = Hive::Modules::Doctor.new(inspector: inspector, store: store).check("demo")

      refute result.fetch("healthy")
      assert_equal "error", check(result, "secret_binding").fetch("status")
      assert_equal "error", check(result, "execution_snapshot").fetch("status")
      assert_equal "warning", check(result, "activation_barrier").fetch("status")
      assert_equal before, tree_digest(root)
      assert File.exist?(barrier)
    end
  end

  private

  def check(result, code)
    result.fetch("checks").find { |row| row.fetch("code") == code }
  end

  def tree_digest(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      [ path, Digest::SHA256.file(path).hexdigest ] if File.file?(path)
    end
  end
end
