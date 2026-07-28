require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/store"
require "hive/commands/module/doctor"
require "hive/commands/module/inspect"
require "hive/commands/module/list"
require "hive/commands/module/status"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/inspector"
require "json_schemer"

class ModuleStatusCommandTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 14, 0, 0)

  def test_list_inspect_status_and_doctor_share_redacted_projection
    with_fixture do |project, store, inspector|
      list = call(Hive::Commands::Module::List, project, store, inspector)
      inspect = call(Hive::Commands::Module::Inspect, project, store, inspector, "demo")
      status = call(Hive::Commands::Module::Status, project, store, inspector, "")
      named_status = call(Hive::Commands::Module::Status, project, store, inspector, "demo")
      doctor = call(Hive::Commands::Module::Doctor, project, store, inspector, "demo")

      assert_equal inspect.fetch("modules"), status.fetch("modules")
      assert_equal inspect.fetch("modules"), named_status.fetch("modules")
      assert_equal list.fetch("modules"), status.fetch("modules")
      assert_equal inspect.fetch("modules").first, doctor.fetch("status")
      [ list, inspect, status, doctor ].each do |payload|
        refute_includes JSON.generate(payload), "secret-value"
        schema = JSONSchemer.schema(Pathname(Hive::Schemas.schema_path(payload.fetch("schema"))))
        assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      end
      assert_raises(Hive::ConfigError) do
        call(Hive::Commands::Module::Status, project, store, inspector, "missing")
      end
    end
  end

  private

  def call(klass, project, store, inspector, *arguments)
    klass.new(
      *arguments, project_root: project, json: true, stdout: StringIO.new,
      store: store, inspector: inspector
    ).call!
  end

  def with_fixture
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      package = File.join(project, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(state)
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => "MODULE_TOKEN" },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      inspector = Hive::Modules::Inspector.new(
        store: store, project_id: "project-1",
        attempt_store: Hive::Attempts::Store.new(root: File.join(project, "attempts"), create_directories: false),
        secret_availability: ->(_name) { false }, clock: -> { NOW }
      )
      yield project, store, inspector
    end
  end
end
