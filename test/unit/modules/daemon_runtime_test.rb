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

  FinalAttempt = Struct.new(:state, :outcome, :retry_charge) do
    def final? = true
    def [](key) = key == "retry_charge" ? retry_charge : nil
  end

  class FetchStore
    def initialize(attempt)
      @attempt = attempt
    end

    def fetch(_attempt_id) = @attempt
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

  def test_capacity_deferred_retry_waits_one_hour_before_another_admission
    with_runtime do |runtime|
      runtime.fetch(:module_dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      first = runtime.fetch(:attempt_store).scan.records.first
      terminalize(runtime.fetch(:attempt_store), first, outcome: "failed")
      capacity = Hive::Attempts::DispatchResult.new(
        status: :deferred, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: "capacity"
      )
      calls = 0
      capacity_dispatcher = Object.new
      capacity_dispatcher.define_singleton_method(:dispatch_module_hook) do |**_attributes|
        calls += 1
        capacity
      end
      daemon = Hive::Modules::DaemonRuntime.new(
        attempt_store: runtime.fetch(:attempt_store),
        attempt_dispatcher: capacity_dispatcher,
        registry: -> { [ runtime.fetch(:entry) ] }
      )

      daemon.tick(now: NOW + 3)
      assert_equal 1, calls
      assert_equal "retrying", current_run(runtime).fetch("status")

      daemon.tick(now: NOW + 3 + Hive::Modules::DaemonRuntime::RETRY_DELAY_SEC - 1)
      assert_equal 1, calls

      daemon.tick(now: NOW + 3 + Hive::Modules::DaemonRuntime::RETRY_DELAY_SEC)
      assert_equal 2, calls
    end
  end

  def test_uninstall_closes_pending_retry_before_idle_and_reinstall_does_not_replay
    with_runtime do |runtime|
      runtime.fetch(:module_dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      first = runtime.fetch(:attempt_store).scan.records.first
      terminalize(runtime.fetch(:attempt_store), first, outcome: "failed")
      runtime.fetch(:store).uninstall("demo", now: NOW + 2)

      result = runtime.fetch(:daemon_runtime).tick(now: NOW + 3).first

      assert_equal :idle, result.fetch(:status)
      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
      assert_equal "failed", current_run(runtime).fetch("status")
      assert_equal "retry_closed", current_run(runtime).dig("retry", "reason")

      current = runtime.fetch(:store).selected("demo", include_tombstone: true)
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: runtime.fetch(:descriptor),
        generation: runtime.fetch(:resolution), current: current,
        current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "task" => true }, grants: exact_grants(runtime.fetch(:descriptor)),
        now: NOW + 4
      )
      runtime.fetch(:store).apply(
        preview, package_root: runtime.fetch(:package),
        resolution: runtime.fetch(:resolution), now: NOW + 4
      )
      runtime.fetch(:store).enable("demo", now: NOW + 5)

      runtime.fetch(:daemon_runtime).tick(now: NOW + 6)

      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
      assert_equal "retry_closed", current_run(runtime).dig("retry", "reason")
    end
  end

  def test_schedule_tick_coalesces_and_dispatches_a_due_occurrence
    with_runtime(schedules: [ "* * * * *" ], publish_event: false) do |runtime|
      result = runtime.fetch(:daemon_runtime).tick(now: NOW + 180).first
      events = Hive::Modules::EventLedger.new(
        root: File.join(runtime.fetch(:store).hive_state_path, "module-runtime")
      ).all

      assert_equal :ok, result.fetch(:status)
      assert_equal 1, result.fetch(:schedules)
      schedule = events.find { |event| event["event_name"] == "schedule" }
      assert_equal "* * * * *", schedule.dig("payload", "schedule")
      assert_equal "demo", schedule.dig("payload", "target_module")
      assert_operator schedule.dig("payload", "missed_windows"), :>=, 1

      next_result = runtime.fetch(:daemon_runtime).tick(now: NOW + 240).first
      assert_equal 1, next_result.fetch(:schedules)
    end
  end

  def test_patrol_native_schedule_is_suppressed_until_module_owns_mutation
    with_runtime(
      schedules: [ "* * * * *" ],
      publish_event: false,
      module_name: "patrol",
      migration_owner: ->(_entry, _module_name) { "legacy" }
    ) do |runtime|
      ledger = Hive::Modules::EventLedger.new(
        root: File.join(runtime.fetch(:store).hive_state_path, "module-runtime")
      )
      count = runtime.fetch(:daemon_runtime).send(
        :dispatch_schedules,
        runtime.fetch(:store).selections,
        store: runtime.fetch(:store),
        ledger: ledger,
        entry: runtime.fetch(:entry),
        now: NOW + 180
      )

      assert_equal 0, count
      assert_empty ledger.all
    end

    with_runtime(
      schedules: [ "* * * * *" ],
      publish_event: false,
      module_name: "patrol",
      migration_owner: ->(_entry, _module_name) { "module" }
    ) do |runtime|
      ledger = Hive::Modules::EventLedger.new(
        root: File.join(runtime.fetch(:store).hive_state_path, "module-runtime")
      )
      count = runtime.fetch(:daemon_runtime).send(
        :dispatch_schedules,
        runtime.fetch(:store).selections,
        store: runtime.fetch(:store),
        ledger: ledger,
        entry: runtime.fetch(:entry),
        now: NOW + 180
      )

      assert_equal 1, count
      assert_equal "patrol", ledger.all.fetch(0).dig("payload", "target_module")
    end
  end

  def test_tick_drains_a_preexisting_event_once
    with_runtime do |runtime|
      first = runtime.fetch(:daemon_runtime).tick(now: NOW + 1).first
      second = runtime.fetch(:daemon_runtime).tick(now: NOW + 2).first
      decisions = Hive::Modules::DecisionJournal.new(
        root: File.join(
          runtime.fetch(:store).hive_state_path,
          "module-runtime"
        )
      ).all

      assert_equal 1, first.fetch(:decisions)
      assert_equal 0, second.fetch(:decisions)
      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
      assert_equal 1, decisions.length
      assert_equal "launch",
                   decisions.fetch(0).fetch("outcome")
    end
  end

  def test_injected_dispatcher_factory_receives_exact_runtime_custody
    calls = []
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) do |**_attributes|
      Object.new
    end
    factory = lambda do |**dependencies|
      calls << dependencies
      dispatcher
    end

    with_runtime(dispatcher_factory: factory) do |runtime|
      result =
        runtime.fetch(:daemon_runtime).tick(
          now: NOW + 1
        ).fetch(0)
      dependencies = calls.fetch(0)

      assert_equal 1, calls.length
      assert_equal(
        %i[
          attempt_dispatcher attempt_store clock decision_journal
          project project_id store
        ],
        dependencies.keys.sort
      )
      assert_instance_of Hive::ModulePackage::ManagedStore,
                         dependencies.fetch(:store)
      assert_equal runtime.fetch(:store).hive_state_path,
                   dependencies.fetch(:store).hive_state_path
      assert_same runtime.fetch(:attempt_store),
                  dependencies.fetch(:attempt_store)
      assert_same runtime.fetch(:attempt_dispatcher),
                  dependencies.fetch(:attempt_dispatcher)
      assert_equal "project-1",
                   dependencies.fetch(:project_id)
      assert_equal "demo", dependencies.fetch(:project)
      assert_instance_of Hive::Modules::DecisionJournal,
                         dependencies.fetch(:decision_journal)
      assert_equal(
        File.join(
          runtime.fetch(:store).hive_state_path,
          "module-runtime"
        ),
        dependencies.fetch(:decision_journal).root
      )
      assert_equal NOW + 1,
                   dependencies.fetch(:clock).call
      assert_equal :ok, result.fetch(:status)
      assert_equal 1, result.fetch(:decisions)
    end
  end

  def test_terminal_success_and_exhausted_failure_finalize_run_receipts
    with_runtime do |runtime|
      runtime.fetch(:module_dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      attempt = runtime.fetch(:attempt_store).scan.records.first
      terminalize(runtime.fetch(:attempt_store), attempt, outcome: "succeeded")

      runtime.fetch(:daemon_runtime).tick(now: NOW + 3)
      run = current_run(runtime)
      assert_equal "succeeded", run.fetch("status")
      assert_equal "complete", run.dig("retry", "status")
    end

    with_runtime do |runtime|
      runtime.fetch(:module_dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      fake_store = FetchStore.new(FinalAttempt.new("terminal", "failed", 2))
      daemon = Hive::Modules::DaemonRuntime.new(
        attempt_store: fake_store, attempt_dispatcher: runtime.fetch(:attempt_dispatcher),
        registry: -> { [ runtime.fetch(:entry) ] }
      )

      daemon.tick(now: NOW + 3)
      run = current_run(runtime)
      assert_equal "failed", run.fetch("status")
      assert_equal "exhausted", run.dig("retry", "status")
    end
  end

  def test_empty_and_corrupt_projects_return_idle_or_bounded_blocked_results
    with_tmp_dir do |root|
      attempt_store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      attempt_dispatcher = Hive::Attempts::Dispatcher.new(
        store: attempt_store, launcher: Launcher.new,
        capability_generator: -> { CAPABILITY }
      )
      defaulted = Hive::Modules::DaemonRuntime.new(
        attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        registry: -> { [] }
      )
      assert_empty defaulted.tick

      idle_entry = {
        "name" => "idle", "hive_state_path" => File.join(root, "idle-state"),
        "project_id" => "idle-id"
      }
      idle = Hive::Modules::DaemonRuntime.new(
        attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        registry: -> { [ idle_entry ] }
      ).tick(now: NOW).first
      assert_equal :idle, idle.fetch(:status)

      corrupt_entry = idle_entry.merge(
        "name" => "corrupt", "hive_state_path" => File.join(root, "corrupt-state")
      )
      corrupt_store = Hive::ModulePackage::ManagedStore.new(corrupt_entry.fetch("hive_state_path"))
      selection_path = corrupt_store.send(:selection_path, "demo")
      FileUtils.mkdir_p(File.dirname(selection_path))
      File.write(selection_path, "{bad")
      blocked = Hive::Modules::DaemonRuntime.new(
        attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        registry: -> { [ corrupt_entry ] }
      ).tick(now: NOW).first
      assert_equal :blocked, blocked.fetch(:status)
      assert_match(/malformed|JSON/, blocked.fetch(:reason))
    end
  end

  def test_setup_identity_cursor_and_retry_timestamp_validation_fail_closed
    daemon = Hive::Modules::DaemonRuntime.new(
      attempt_store: Object.new, attempt_dispatcher: Object.new, registry: -> { [] }
    )
    selection = { "name" => "demo" }
    store = Object.new
    store.define_singleton_method(:promote_setup_outbox) do |_name, &block|
      block.call(
        "project_id" => "foreign", "project" => "demo"
      )
    end
    error = assert_raises(Hive::ConfigError) do
      daemon.send(
        :promote_setup_outboxes, store, [ selection ],
        ledger: Object.new,
        entry: { "project_id" => "project-1", "name" => "demo" },
        now: NOW
      )
    end
    assert_match(/another project/, error.message)

    with_tmp_dir do |root|
      path = File.join(root, "cursor.json")
      File.write(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          "schema_version" => 1, "cursor" => -1
        )
      )
      assert_raises(Hive::ConfigError) { daemon.send(:read_event_cursor, path) }
    end

    assert_raises(Hive::ConfigError) do
      daemon.send(
        :retry_deferred?,
        { "status" => "retrying", "updated_at" => "not-a-timestamp" },
        NOW
      )
    end
  end

  def test_tick_promotes_install_setup_outbox_once_and_targets_only_enabled_setup_hooks
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "setup", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "project.registered" ], "concurrency" => "drop"
        },
        {
          "id" => "optional-setup",
          "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => false, "schedules" => [],
          "events" => [ "project.registered" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package, hooks: hooks)
      state = File.join(root, "project", ".hive-state")
      store = Hive::ModulePackage::ManagedStore.new(state)
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "setup" => true, "optional-setup" => false },
        grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(
        preview, package_root: package, resolution: resolution,
        setup_context: { project_id: "project-1", project: "demo" },
        now: NOW - 60
      )
      attempt_store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      attempt_dispatcher = Hive::Attempts::Dispatcher.new(
        store: attempt_store, launcher: Launcher.new,
        capability_generator: -> { CAPABILITY }
      )
      entry = {
        "name" => "demo", "path" => File.join(root, "project"),
        "hive_state_path" => state, "project_id" => "project-1"
      }
      daemon = Hive::Modules::DaemonRuntime.new(
        attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        registry: -> { [ entry ] }
      )

      first = daemon.tick(now: NOW).first
      second = daemon.tick(now: NOW + 1).first

      assert_equal 1, first.fetch(:decisions)
      assert_equal 0, second.fetch(:decisions)
      assert_nil store.inspect_setup_outbox("demo")
      assert_equal 1, attempt_store.scan.records.size
      event = Hive::Modules::EventLedger.new(
        root: File.join(state, "module-runtime")
      ).all.fetch(0)
      assert_equal "project.registered", event.fetch("event_name")
      assert_equal "module_install", event.dig("source", "type")
      assert_equal [ "setup" ], event.dig("payload", "target_hooks")
    end
  end

  def test_default_migration_owner_reads_the_durable_owner
    with_tmp_dir do |root|
      runtime = Hive::Modules::DaemonRuntime.new(
        attempt_store: Object.new,
        attempt_dispatcher: Object.new,
        registry: -> { [] }
      )
      owner = runtime.instance_variable_get(:@migration_owner)

      assert_equal(
        "legacy",
        owner.call(
          {
            "path" => root,
            "hive_state_path" => File.join(root, ".hive-state")
          },
          "patrol"
        )
      )
    end
  end

  private

  def with_runtime(schedules: [], publish_event: true, module_name: "demo",
                   migration_owner: nil, dispatcher_factory: nil)
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => schedules,
          "events" => [ "task.completed" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(
        package, name: module_name, hooks: hooks
      )
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
      event = if publish_event
        ledger.record(
          project_id: "project-1", project: "demo", event_name: "task.completed",
          occurred_at: NOW, source: { type: "task", id: "task-1" },
          idempotency_key: "task-1", payload: {}, recorded_at: NOW
        ).event
      end
      journal = Hive::Modules::DecisionJournal.new(root: File.join(state, "module-runtime"))
      module_dispatcher = Hive::Modules::Dispatcher.new(
        store: store, attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        project_id: "project-1", project: "demo", decision_journal: journal, clock: -> { NOW }
      )
      entry = {
        "name" => "demo", "path" => File.join(root, "project"),
        "hive_state_path" => state, "project_id" => "project-1"
      }
      daemon_options = {
        attempt_store: attempt_store, attempt_dispatcher: attempt_dispatcher,
        registry: -> { [ entry ] }, migration_owner: migration_owner
      }
      daemon_options[:dispatcher_factory] =
        dispatcher_factory if dispatcher_factory
      daemon_runtime =
        Hive::Modules::DaemonRuntime.new(**daemon_options)
      yield(
        store: store, attempt_store: attempt_store, module_dispatcher: module_dispatcher,
        attempt_dispatcher: attempt_dispatcher, daemon_runtime: daemon_runtime,
        event: event, entry: entry, package: package, resolution: resolution,
        descriptor: descriptor
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


  def current_run(runtime)
    path = Dir.glob(File.join(runtime.fetch(:store).runtime_path("demo"), "runs", "*.json")).fetch(0)
    JSON.parse(File.binread(path))
  end
end
