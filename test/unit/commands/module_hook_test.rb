require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/dispatcher"
require "hive/attempts/store"
require "hive/commands/module_hook"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/decision_journal"
require "hive/modules/dispatcher"
require "hive/modules/entrypoints"
require "hive/modules/event_ledger"

class CommandsModuleHookTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 10, 0, 0)

  class Launcher
    attr_reader :record
    def preflight! = true
    def launch(record, claim_capability:)
      @record = record
      { "claimed" => !claim_capability.empty? }
    end
  end

  def teardown
    Hive::Modules::Entrypoints.reset!
    super
  end

  def test_private_worker_uses_persisted_snapshot_and_registered_entrypoint
    with_tmp_global_config do
      with_tmp_dir do |project|
        state = File.join(project, ".hive-state")
        package = File.join(project, "package")
        hooks = [
          {
            "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
            "default_enabled" => true, "schedules" => [],
            "events" => [ "task.completed" ], "concurrency" => "drop"
          }
        ]
        resolution, descriptor = write_module_package(package, hooks: hooks)
        store = Hive::ModulePackage::ManagedStore.new(state)
        preview = Hive::ModulePackage::Preview.build(
          operation: "install", descriptor: descriptor, generation: resolution,
          current: nil, current_configuration: nil,
          settings: { "mode" => "safe", "api_token" => nil }, hooks: { "task" => true },
          grants: exact_grants(descriptor), now: NOW - 60
        )
        store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
        entry = Hive::Config.register_project(name: "demo", path: project)
        ledger = Hive::Modules::EventLedger.new(root: File.join(state, "module-runtime"))
        event = ledger.record(
          project_id: entry.fetch("project_id"), project: "demo", event_name: "task.completed",
          occurred_at: NOW, source: { type: "task", id: "task-1" },
          idempotency_key: "task-1", payload: {}, recorded_at: NOW
        ).event
        attempt_store = Hive::Attempts::Store.new(root: File.join(project, "attempts"))
        launcher = Launcher.new
        attempts = Hive::Attempts::Dispatcher.new(
          store: attempt_store, launcher: launcher,
          id_generator: -> { "attempt-1" }, capability_generator: -> { "c" * 64 }
        )
        dispatcher = Hive::Modules::Dispatcher.new(
          store: store, attempt_store: attempt_store, attempt_dispatcher: attempts,
          project_id: entry.fetch("project_id"), project: "demo",
          decision_journal: Hive::Modules::DecisionJournal.new(root: File.join(state, "module-runtime")),
          clock: -> { NOW }
        )
        dispatcher.dispatch(module_name: "demo", hook_id: "task", event: event)
        calls = []
        Hive::Modules::Entrypoints.register("demo.run") { |context| calls << context; 0 }

        command = Hive::Commands::ModuleHook.from_argv(launcher.record["worker_argv"].drop(2))
        assert_equal 0, command.call
        assert_equal event, calls.fetch(0).fetch(:event)
        assert_equal "safe", calls.fetch(0).fetch(:configuration).settings.fetch("mode")
      end
    end
  end
end
