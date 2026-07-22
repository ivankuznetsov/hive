require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/dispatcher"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/daemon_runtime"
require "hive/modules/event_ledger"

class ModulesDaemonRuntimeTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 10, 0, 0)
  CAPABILITY = "c" * 64

  class Launcher
    def preflight! = true
    def launch(_record, claim_capability:) = { "claimed" => !claim_capability.empty? }
  end

  def test_failed_hook_attempt_retries_with_same_occurrence_and_bounded_charge
    with_runtime do |runtime|
      runtime.fetch(:module_dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      first = runtime.fetch(:attempt_store).scan.records.first
      terminalize(runtime.fetch(:attempt_store), first, outcome: "failed")

      result = runtime.fetch(:daemon_runtime).tick(now: NOW + 3).first
      attempts = runtime.fetch(:attempt_store).scan.records.sort_by { |record| record["retry_charge"] }

      assert_equal :ok, result.fetch(:status)
      assert_equal 2, attempts.size
      assert_equal 1, attempts.last["retry_charge"]
      assert_equal first.attempt_id, attempts.last["predecessor_attempt_id"]
      assert_equal first.subject, attempts.last.subject
    end
  end

  def test_disable_closes_pending_retry_without_replay
    with_runtime do |runtime|
      runtime.fetch(:module_dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      first = runtime.fetch(:attempt_store).scan.records.first
      terminalize(runtime.fetch(:attempt_store), first, outcome: "failed")
      runtime.fetch(:store).disable("demo", now: NOW + 2)

      runtime.fetch(:daemon_runtime).tick(now: NOW + 3)

      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
      run = JSON.parse(Dir.glob(File.join(runtime.fetch(:store).runtime_path("demo"), "runs", "*.json")).then { |paths| File.read(paths.first) })
      assert_equal "failed", run.fetch("status")
      assert_equal "retry_closed", run.dig("retry", "reason")
    end
  end

  private

  def with_runtime
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "task.completed" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, hooks: hooks)
      state = File.join(root, "project", ".hive-state")
      store = Hive::ModulePackage::ManagedStore.new(state)
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil }, hooks: { "task" => true },
        grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      attempt_store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      counter = 0
      attempt_dispatcher = Hive::Attempts::Dispatcher.new(
        store: attempt_store, launcher: Launcher.new,
        id_generator: -> { counter += 1; "attempt-#{counter}" },
        capability_generator: -> { CAPABILITY }
      )
      ledger = Hive::Modules::EventLedger.new(root: File.join(state, "module-runtime"))
      event = ledger.record(
        project_id: "project-1", project: "demo", event_name: "task.completed",
        occurred_at: NOW, source: { type: "task", id: "task-1" },
        idempotency_key: "task-1", payload: {}, recorded_at: NOW
      ).event
      journal = Hive::Modules::DecisionJournal.new(root: File.join(state, "module-runtime"))
      module_dispatcher = Hive::Modules::Dispatcher.new(
        store: store, attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        project_id: "project-1", project: "demo", decision_journal: journal, clock: -> { NOW }
      )
      entry = {
        "name" => "demo", "path" => File.join(root, "project"),
        "hive_state_path" => state, "project_id" => "project-1"
      }
      daemon_runtime = Hive::Modules::DaemonRuntime.new(
        attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        registry: -> { [ entry ] }
      )
      yield(
        store: store, attempt_store: attempt_store, module_dispatcher: module_dispatcher,
        daemon_runtime: daemon_runtime, event: event
      )
    end
  end

  def terminalize(store, launching, outcome:)
    claimed = store.claim(
      launching, owner: { "pid" => 1 }, claim_capability: CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 1)
    store.terminalize(
      running, outcome: outcome, exit_status: 1, final_checkpoint: running.checkpoint,
      output_references: [],
      log_reference: { "path" => "logs/a", "size" => 0, "sha256" => "0" * 64 },
      now: NOW + 2
    )
  end
end
