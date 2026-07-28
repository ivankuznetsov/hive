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
      File.write(File.join(run_root, "corrupt.json"), "{bad")
      barrier = File.join(store.runtime_path("demo"), "activation-barrier.json")
      File.write(barrier, "{}")
      inspector = Hive::Modules::Inspector.new(
        store: store, project_id: "project-1",
        attempt_store: Hive::Attempts::Store.new(root: File.join(root, "attempts"), create_directories: false),
        secret_availability: ->(_name) { false }, clock: -> { NOW }
      )
      before = tree_digest(root)

      result = Hive::Modules::Doctor.new(inspector: inspector, store: store).check("demo")

      refute result.fetch("healthy")
      assert_equal "error", check(result, "secret_binding").fetch("status")
      assert_equal "error", check(result, "execution_snapshot").fetch("status")
      assert result.fetch("checks").any? { |row| row["subject"] == "corrupt" && row["status"] == "error" }
      assert_equal "error", check(result, "activation_barrier").fetch("status")
      assert_equal "error", check(result, "target_bindings").fetch("status")
      assert_equal before, tree_digest(root)
      assert File.exist?(barrier)
    end
  end

  def test_valid_runtime_and_integrity_edges_are_reported_without_mutation
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor),
        now: NOW - 60
      )
      store.apply(
        preview, package_root: package, resolution: resolution, now: NOW - 60
      )
      run_root = File.join(store.runtime_path("demo"), "runs")
      FileUtils.mkdir_p(run_root)
      File.write(
        File.join(run_root, "valid.json"),
        JSON.generate(
          "run_id" => "valid-run", "status" => "running",
          "execution_snapshot" => valid_snapshot
        )
      )
      inspector = Hive::Modules::Inspector.new(
        store: store, project_id: "project-1", clock: -> { NOW }
      )
      doctor = Hive::Modules::Doctor.new(inspector: inspector, store: store)

      runtime = doctor.send(:runtime_checks, "demo")
      assert_equal "ok", runtime.fetch(0).fetch("status")
      assert_equal "valid-run", runtime.fetch(0).fetch("subject")

      migration = doctor.send(:migration_checks, "patrol")
      assert_equal "error", migration.fetch(0).fetch("status")
      assert_equal "unadopted", migration.fetch(0).fetch("subject")

      original_new = Hive::Modules::TargetExecutor.method(:new)
      healthy_executor = Object.new
      healthy_executor.define_singleton_method(:validate_generation!) { |*| true }
      Hive::Modules::TargetExecutor.define_singleton_method(:new) { healthy_executor }
      begin
        rows = doctor.send(
          :module_integrity_checks, "demo", inspector.inspect("demo")
        )
        assert_equal "ok", rows.find { |row| row["code"] == "target_bindings" }.fetch("status")
      ensure
        Hive::Modules::TargetExecutor.define_singleton_method(:new, original_new)
      end

      store.define_singleton_method(:inspect_setup_outbox) do |_name|
        raise Hive::ConfigError, "corrupt outbox"
      end
      original_validate = Hive::ModulePackage::Validator.method(:validate!)
      Hive::ModulePackage::Validator.define_singleton_method(:validate!) do |*|
        raise Hive::ConfigError, "corrupt manifest"
      end
      begin
        rows = doctor.send(
          :module_integrity_checks, "demo", inspector.inspect("demo")
        )
      ensure
        Hive::ModulePackage::Validator.define_singleton_method(
          :validate!, original_validate
        )
      end
      assert_equal "error", rows.find { |row| row["code"] == "manifest_inventory" }.fetch("status")
      assert_equal "error", rows.find { |row| row["code"] == "setup_outbox" }.fetch("status")

      malformed_status = { "active" => { "source_commit" => "a" * 40 } }
      rows = doctor.send(:module_integrity_checks, "demo", malformed_status)
      assert rows.all? { |row| row.fetch("status") == "error" }

      configuration = Struct.new(:digest, :contract).new(
        "d" * 64,
        {
          "hooks" => [
            { "id" => "schedule" }
          ]
        }
      )
      store.define_singleton_method(:inspect_hooks) { |_name| {} }
      refute doctor.send(:hooks_valid?, "demo", configuration)
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

  def valid_snapshot
    {
      "schema_version" => 1,
      "subject" => {
        "kind" => "module_hook", "project_id" => "project-1",
        "module" => "demo", "hook" => "schedule",
        "event_id" => "event-1", "occurrence_id" => "event-1",
        "event_name" => "schedule", "module_generation" => "a" * 40,
        "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
      },
      "descriptor" => {
        "id" => "schedule",
        "target" => { "kind" => "entrypoint", "id" => "demo.run" }
      },
      "target" => { "kind" => "entrypoint", "id" => "demo.run" },
      "configuration" => { "mode" => "safe" },
      "grants" => { "filesystem_read" => [ "repository" ] },
      "ownership_generation" => "1:#{'a' * 40}",
      "task_input_epoch" => 1
    }
  end
end
