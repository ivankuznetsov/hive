require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/dispatcher"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/dispatcher"
require "hive/modules/event_ledger"

class ModulesDispatcherTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 10, 0, 0)

  class Launcher
    attr_reader :launches

    def initialize
      @launches = []
    end

    def preflight! = true

    def launch(record, claim_capability:)
      @launches << [ record, claim_capability ]
      { "claimed" => true }
    end
  end

  def test_replay_creates_one_attempt_and_two_explainable_decisions
    with_runtime do |runtime|
      first = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      second = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )

      assert first.launched?
      refute second.launched?
      assert_equal "duplicate", second.decision.fetch("reason")
      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
      attempt = runtime.fetch(:attempt_store).scan.records.first
      assert attempt.module_hook?
      assert_equal "demo", attempt.subject.fetch("module")
      assert_equal 2, runtime.fetch(:journal).all.size
      assert_equal 1, runtime.fetch(:launcher).launches.size
    end
  end

  def test_disable_and_activation_barrier_skip_without_attempt_and_barrier_preserves_cursor
    with_runtime do |runtime|
      store = runtime.fetch(:store)
      store.disable("demo", now: NOW)
      disabled_event = record_event(runtime, idempotency_key: "task-8", occurred_at: NOW + 2)
      disabled = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: disabled_event
      )
      assert_equal "disabled", disabled.decision.fetch("reason")

      store.enable("demo", now: NOW + 3)
      barrier = File.join(store.runtime_path("demo"), "activation-barrier.json")
      File.write(barrier, "{}")
      fenced_event = record_event(runtime, idempotency_key: "task-9", occurred_at: NOW + 4)
      before = JSON.parse(File.read(File.join(store.runtime_path("demo"), "hooks.json")))
      fenced = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: fenced_event
      )
      after = JSON.parse(File.read(File.join(store.runtime_path("demo"), "hooks.json")))

      assert_equal "activation_fenced", fenced.decision.fetch("reason")
      assert_nil before.dig("hooks", "task", "cursor")
      assert_nil after.dig("hooks", "task", "cursor")
      assert_empty runtime.fetch(:attempt_store).scan.records
    end
  end

  def test_dry_run_uses_same_evaluator_without_persistence
    with_runtime do |runtime|
      store = runtime.fetch(:store)
      hooks_path = File.join(store.runtime_path("demo"), "hooks.json")
      before = File.binread(hooks_path)
      result = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event), dry_run: true
      )

      assert result.launched?
      assert_nil result.decision.fetch("decision_id")
      assert_empty runtime.fetch(:journal).all
      assert_empty runtime.fetch(:attempt_store).scan.records
      assert_equal before, File.binread(hooks_path)
    end
  end

  private

  def with_runtime
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [ "0 * * * *" ],
          "events" => [ "task.completed" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, hooks: hooks)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil }, hooks: { "task" => true },
        grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      attempt_store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      launcher = Launcher.new
      attempt_dispatcher = Hive::Attempts::Dispatcher.new(
        store: attempt_store, launcher: launcher,
        id_generator: -> { "attempt-1" }, capability_generator: -> { "c" * 64 }
      )
      ledger = Hive::Modules::EventLedger.new(root: File.join(root, ".hive-state", "module-runtime"))
      journal_counter = 0
      journal = Hive::Modules::DecisionJournal.new(
        root: File.join(root, ".hive-state", "module-runtime"),
        id_generator: -> { journal_counter += 1; "decision-#{journal_counter}" }
      )
      dispatcher = Hive::Modules::Dispatcher.new(
        store: store, attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        project_id: "project-1", project: "demo", decision_journal: journal, clock: -> { NOW }
      )
      runtime = {
        root: root, store: store, attempt_store: attempt_store, launcher: launcher,
        ledger: ledger, journal: journal, dispatcher: dispatcher
      }
      runtime[:event] = record_event(runtime, idempotency_key: "task-7", occurred_at: NOW + 1)
      yield runtime
    end
  end

  def record_event(runtime, idempotency_key:, occurred_at:)
    runtime.fetch(:ledger).record(
      project_id: "project-1", project: "demo", event_name: "task.completed",
      occurred_at: occurred_at, source: { type: "task", id: idempotency_key },
      idempotency_key: idempotency_key, payload: { "task_id" => idempotency_key },
      recorded_at: occurred_at
    ).event
  end
end
