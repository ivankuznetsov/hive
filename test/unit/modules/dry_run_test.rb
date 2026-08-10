require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/dry_run"

class ModulesDryRunTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 13, 0, 0)

  def test_uses_production_evaluator_without_creating_runtime_state
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [], "events" => [ "task.completed" ],
          "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      settings = [
        { "name" => "mode", "type" => "enum", "required" => true,
          "default" => "safe", "values" => %w[safe fast] },
        { "name" => "api_token", "type" => "secret", "required" => true, "secret" => true }
      ]
      resolution, descriptor = write_module_package(package, hooks: hooks, settings: settings)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => "MODULE_DRY_TOKEN" }, hooks: { "task" => true },
        grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      before = tree_digest(root)
      dry_run = Hive::Modules::DryRun.new(
        store: store, project_id: "project-1", project: "demo",
        attempt_store: Hive::Attempts::Store.new(root: File.join(root, "attempts"), create_directories: false),
        clock: -> { NOW }
      )

      result = with_env("MODULE_DRY_TOKEN" => "present") do
        dry_run.evaluate(module_name: "demo", event_name: "task.completed", occurred_at: NOW)
      end

      decision = result.fetch("decisions").first
      assert_equal "launch", decision.fetch("outcome")
      assert_equal "admitted", decision.fetch("reason")
      assert_nil decision.fetch("decision_id")
      assert_equal before, tree_digest(root)
      refute File.exist?(File.join(store.hive_state_path, "module-runtime"))

      capacity = Hive::Modules::DryRun.new(
        store: store, project_id: "project-1", project: "demo",
        attempt_store: Hive::Attempts::Store.new(
          root: File.join(root, "attempts"), create_directories: false
        ),
        capacity_probe: ->(**) { true }, clock: -> { NOW }
      )
      blocked = with_env("MODULE_DRY_TOKEN" => "present") do
        capacity.evaluate(
          module_name: "demo", hook_id: "task",
          event_name: "task.completed", occurred_at: NOW
        )
      end
      assert_equal "capacity_blocked", blocked.dig("decisions", 0, "reason")
      assert_equal before, tree_digest(root)
    end
  end

  def test_hook_specific_and_schedule_events_use_strict_pure_envelopes
    with_tmp_dir do |root|
      store = Struct.new(:hive_state_path).new(root)
      attempts = Struct.new(:scan).new(Struct.new(:records).new([]))
      dry_run = Hive::Modules::DryRun.new(
        store: store, attempt_store: attempts,
        project_id: "project-1", project: "demo"
      )
      dispatch = Struct.new(:decision).new({ "outcome" => "skip", "reason" => "disabled" })
      dispatcher = Object.new
      dispatcher.define_singleton_method(:dispatch) { |**_attributes| dispatch }
      dry_run.instance_variable_set(:@dispatcher, dispatcher)

      result = dry_run.evaluate(
        module_name: "demo", hook_id: "task", event_name: "schedule",
        schedule: "0 * * * *"
      )
      assert_equal "0 * * * *", result.dig("event", "payload", "schedule")
      assert_equal "skip", result.fetch("decisions").first.fetch("outcome")

      assert_raises(Hive::ConfigError) do
        dry_run.evaluate(module_name: "demo", hook_id: "task", event_name: "schedule", occurred_at: NOW)
      end
      assert_raises(Hive::ConfigError) do
        dry_run.evaluate(
          module_name: "demo", hook_id: "task", event_name: "task.completed",
          occurred_at: "not-a-time"
        )
      end
    end
  end

  private

  def tree_digest(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      [ path, Digest::SHA256.file(path).hexdigest ] if File.file?(path)
    end
  end
end
