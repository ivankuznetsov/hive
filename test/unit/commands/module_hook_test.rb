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

  def test_worker_rejects_parser_run_and_snapshot_identity_failures
    assert_raises(Hive::ConfigError) do
      Hive::Commands::ModuleHook.from_argv([ "--unknown" ])
    end

    with_tmp_dir do |root|
      store = Object.new
      store.define_singleton_method(:runtime_path) { |_name| root }
      malformed = hook_command(run_id: "short")
      assert_raises(Hive::ConfigError) { malformed.send(:load_run, store) }

      missing = hook_command(run_id: "a" * 64)
      assert_raises(Hive::ConfigError) { missing.send(:load_run, store) }

      runs = File.join(root, "runs")
      FileUtils.mkdir_p(runs)
      File.write(
        File.join(runs, "#{'a' * 64}.json"),
        JSON.generate(
          "run_id" => "different", "event_id" => "event-1", "source_commit" => "b" * 40,
          "configuration_digest" => "c" * 64
        )
      )
      assert_raises(Hive::ConfigError) { missing.send(:load_run, store) }
      File.write(File.join(runs, "#{'a' * 64}.json"), "{bad")
      assert_raises(Hive::ConfigError) { missing.send(:load_run, store) }
    end
  end

  def test_worker_rechecks_target_and_rejects_non_entrypoint_execution
    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))
      configuration = Hive::ModulePackage::Configuration.build(
        descriptor, generation: resolution,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor)
      )
      entry = { "name" => "demo", "hive_state_path" => File.join(root, ".hive-state") }
      run = {
        "execution_snapshot" => {
          "configuration" => configuration.to_h,
          "descriptor" => descriptor.hooks.first
        }
      }
      mismatch = hook_command(target: "other.run", configuration_digest: configuration.digest)
      mismatch.define_singleton_method(:load_run) { |_store| run }

      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { entry }) do
        with_replaced_singleton_method(Hive::ModulePackage::ManagedStore, :new, ->(_path) { Object.new }) do
          assert_raises(Hive::ConfigError) { mismatch.call }
        end
      end

      command_hook = descriptor.hooks.first.merge(
        "target" => { "kind" => "command", "id" => "bin/demo" }
      )
      command_run = { "execution_snapshot" => run.fetch("execution_snapshot").merge("descriptor" => command_hook) }
      unsupported = hook_command(
        target_kind: "command", target: "bin/demo", configuration_digest: configuration.digest
      )
      unsupported.define_singleton_method(:load_run) { |_store| command_run }
      ledger = Object.new
      ledger.define_singleton_method(:fetch) { |_event_id| { "event_id" => "event-1" } }
      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { entry }) do
        with_replaced_singleton_method(Hive::ModulePackage::ManagedStore, :new, ->(_path) { Object.new }) do
          with_replaced_singleton_method(Hive::Modules::EventLedger, :new, ->(**_options) { ledger }) do
            assert_raises(Hive::ConfigError) { unsupported.call }
          end
        end
      end
    end
  end

  def test_worker_rederives_every_admitted_identity_before_executor_dispatch
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
        configuration = Hive::ModulePackage::Configuration.build(
          descriptor, generation: resolution,
          settings: { "mode" => "safe", "api_token" => nil },
          hooks: { "task" => true }, grants: exact_grants(descriptor)
        )
        selection = {
          "epoch" => 4,
          "active" => {
            "source_commit" => resolution.source_commit,
            "configuration_digest" => configuration.digest
          }
        }
        entry = Hive::Config.register_project(name: "demo", path: project)
        event = Hive::Modules::EventLedger.new(root: File.join(state, "module-runtime")).record(
          project_id: entry.fetch("project_id"), project: "demo",
          event_name: "task.completed", occurred_at: NOW,
          source: { type: "task", id: "task-identity" },
          idempotency_key: "task-identity", payload: {}, recorded_at: NOW
        ).event
        attempt = Hive::Modules::HookAttempt.build(
          project: "demo", project_id: entry.fetch("project_id"), module_name: "demo",
          hook: hooks.first, selection: selection, configuration: configuration,
          event: event, package_root: package
        )
        run = {
          "schema_version" => 1, "run_id" => attempt.run_id, "project" => "demo",
          "status" => "running", "source_commit" => resolution.source_commit,
          "configuration_digest" => configuration.digest, "event_id" => event.fetch("event_id"),
          "attempt_id" => "attempt-1", "attempt_ids" => [ "attempt-1" ],
          "subject" => attempt.subject, "argv" => attempt.argv,
          "ownership_generation" => attempt.ownership_generation,
          "task_input_epoch" => attempt.task_input_epoch,
          "created_at" => NOW.iso8601(6), "execution_snapshot" => attempt.execution_snapshot
        }
        calls = []
        executor = ->(**values) { calls << values; 13 }
        command = Hive::Commands::ModuleHook.new(
          "demo", "task", project: "demo", event_id: event.fetch("event_id"),
          target_kind: "entrypoint", target: "demo.run",
          generation: resolution.source_commit, configuration_digest: configuration.digest,
          run_id: attempt.run_id, target_executor: executor
        )
        command.define_singleton_method(:load_run) { |_store| run }

        assert_equal 13, command.call
        assert_equal 1, calls.length

        tampered_runs = [
          deep_copy(run).tap { |row| row["subject"]["project_id"] = "other-project" },
          deep_copy(run).tap { |row| row["subject"]["event_name"] = "project.registered" },
          deep_copy(run).tap { |row| row["execution_snapshot"]["configuration"]["settings"]["mode"] = "fast" },
          deep_copy(run).tap { |row| row["execution_snapshot"]["grants"]["filesystem_read"] = [] },
          deep_copy(run).tap { |row| row["execution_snapshot"]["descriptor"]["target"]["id"] = "other.run" },
          deep_copy(run).tap { |row| row["execution_snapshot"]["target"]["id"] = "other.run" },
          deep_copy(run).tap { |row| row["argv"][-1] = "other-run" },
          deep_copy(run).tap { |row| row["ownership_generation"] = "5:#{resolution.source_commit}" }
        ]
        calls.clear
        tampered_runs.each do |tampered|
          command.define_singleton_method(:load_run) { |_store| tampered }
          assert_raises(Hive::ConfigError) { command.call }
        end
        assert_empty calls
      end
    end
  end

  private

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def hook_command(run_id: "a" * 64, target_kind: "entrypoint", target: "demo.run",
                   configuration_digest: "c" * 64)
    Hive::Commands::ModuleHook.new(
      "demo", "task", project: "demo", event_id: "event-1",
      target_kind: target_kind, target: target, generation: "b" * 40,
      configuration_digest: configuration_digest, run_id: run_id
    )
  end
end
