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

  class ResultDispatcher
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def dispatch_module_hook(**arguments)
      @calls << arguments
      @result
    end
  end

  PreviousAttempt = Struct.new(:attempt_id, :retry_charge) do
    def [](key) = key == "retry_charge" ? retry_charge : nil
  end
  ReplayedAttempt = Struct.new(:attempt_id, :retry_charge) do
    def [](key) = key == "retry_charge" ? retry_charge : nil
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

  def test_recovers_launch_receipt_when_attempt_admission_preceded_decision_append
    with_runtime do |runtime|
      dispatcher = runtime.fetch(:dispatcher)
      context = dispatcher.send(:load_context, "demo", "task")
      hook_attempt = Hive::Modules::HookAttempt.build(
        project: "demo", project_id: "project-1", module_name: "demo",
        hook: context.fetch(:hook), selection: context.fetch(:selection),
        configuration: context.fetch(:configuration), event: runtime.fetch(:event),
        package_root: runtime.fetch(:store).generation_path(
          "demo", context.dig(:selection, "active", "source_commit")
        )
      )
      dispatcher.send(:persist_run, "demo", hook_attempt, runtime.fetch(:event))
      admitted = runtime.fetch(:attempt_dispatcher).dispatch_module_hook(
        generation: hook_attempt, subject: hook_attempt.subject, argv: hook_attempt.argv,
        request_id: "module:#{runtime.dig(:event, 'event_id')}:task",
        provider: "module", interactive: false, now: NOW, project_root: runtime.fetch(:root)
      )
      assert admitted.accepted?
      assert_empty runtime.fetch(:journal).all

      recovered = dispatcher.dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )

      assert recovered.launched?
      assert_equal admitted.attempt.attempt_id, recovered.decision.fetch("attempt_id")
      assert_equal "recovered_launch", recovered.attempt_result.reason
      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
      assert_equal 1, runtime.fetch(:launcher).launches.size
      assert_equal 1, runtime.fetch(:journal).all.size
    end
  end

  def test_terminal_attempt_recovery_stays_eligible_for_finalization
    with_runtime do |runtime|
      dispatcher = runtime.fetch(:dispatcher)
      context = dispatcher.send(:load_context, "demo", "task")
      hook_attempt = Hive::Modules::HookAttempt.build(
        project: "demo", project_id: "project-1", module_name: "demo",
        hook: context.fetch(:hook), selection: context.fetch(:selection),
        configuration: context.fetch(:configuration), event: runtime.fetch(:event),
        package_root: runtime.fetch(:store).generation_path(
          "demo", context.dig(:selection, "active", "source_commit")
        )
      )
      dispatcher.send(:persist_run, "demo", hook_attempt, runtime.fetch(:event))
      admitted = runtime.fetch(:attempt_dispatcher).dispatch_module_hook(
        generation: hook_attempt, subject: hook_attempt.subject, argv: hook_attempt.argv,
        request_id: "module:#{runtime.dig(:event, 'event_id')}:task",
        provider: "module", interactive: false, now: NOW, project_root: runtime.fetch(:root)
      )
      claimed = runtime.fetch(:attempt_store).claim(
        admitted.attempt, owner: { "pid" => 1 }, claim_capability: "c" * 64,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = runtime.fetch(:attempt_store).first_heartbeat(
        claimed, stale_sec: 30, now: NOW + 1
      )
      runtime.fetch(:attempt_store).terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: running.checkpoint, output_references: [],
        log_reference: { "path" => "logs/a", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 2
      )

      recovered = dispatcher.dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      run = JSON.parse(File.binread(File.join(
        runtime.fetch(:store).runtime_path("demo"), "runs", "#{hook_attempt.run_id}.json"
      )))

      assert recovered.launched?
      assert_equal :terminal_replay, recovered.attempt_result.status
      assert_equal "running", run.fetch("status")
      assert_equal admitted.attempt.attempt_id, run.fetch("attempt_id")
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

  def test_dispatch_event_projects_and_dispatches_every_active_hook
    with_runtime do |runtime|
      projected = runtime.fetch(:dispatcher).dispatch_event(runtime.fetch(:event), dry_run: true)
      assert_equal [ "admitted" ], projected.map { |result| result.decision.fetch("reason") }
      assert_empty runtime.fetch(:journal).all

      dispatched = runtime.fetch(:dispatcher).dispatch_event(runtime.fetch(:event))
      assert_equal 1, dispatched.size
      assert dispatched.first.launched?
      assert_equal 1, runtime.fetch(:attempt_store).scan.records.size
    end
  end

  def test_missing_module_or_hook_uses_a_closed_null_configuration
    with_runtime do |runtime|
      missing_module = runtime.fetch(:dispatcher).dispatch(
        module_name: "missing", hook_id: "task", event: runtime.fetch(:event)
      )
      missing_hook = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "missing", event: runtime.fetch(:event)
      )

      assert_equal "not_installed", missing_module.decision.fetch("reason")
      assert_equal "invalid_binding", missing_hook.decision.fetch("reason")
      assert_nil missing_module.decision.fetch("configuration_digest")
      assert_nil missing_hook.decision.fetch("concurrency")
    end
  end

  def test_attempt_admission_outcomes_are_recorded_as_skip_reasons
    rows = {
      existing_live: [ nil, "duplicate", "running" ],
      terminal_replay: [ nil, "terminal_replay", "failed" ],
      deferred_capacity: [ "capacity", "capacity_blocked", "failed" ],
      deferred_handoff: [ "launch_handoff_failed", "launch_handoff_failed", "retrying" ],
      deferred_other: [ "provider", "concurrency_blocked", "failed" ]
    }
    rows.each do |name, (reason, expected_reason, expected_status)|
      status = name.to_s.start_with?("deferred") ? :deferred : name
      result = Hive::Attempts::DispatchResult.new(
        status: status, attempt: nil, receipt: nil, attach_descriptor: nil, reason: reason
      )
      result_dispatcher = ResultDispatcher.new(result)
      with_runtime(attempt_dispatcher: result_dispatcher) do |runtime|
        dispatch = runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
        )

        assert_equal expected_reason, dispatch.decision.fetch("reason"), name
        run = JSON.parse(Dir[File.join(runtime.fetch(:store).runtime_path("demo"), "runs", "*.json")].then do |paths|
          File.binread(paths.fetch(0))
        end)
        assert_equal expected_status, run.fetch("status"), name
      end
    end
  end

  def test_terminal_replay_with_a_durable_attempt_remains_reconcilable
    replayed = ReplayedAttempt.new("attempt-replayed", 1)
    result = Hive::Attempts::DispatchResult.new(
      status: :terminal_replay, attempt: replayed, receipt: {},
      attach_descriptor: nil, reason: nil
    )
    with_runtime(attempt_dispatcher: ResultDispatcher.new(result)) do |runtime|
      dispatch = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      run = JSON.parse(Dir[
        File.join(runtime.fetch(:store).runtime_path("demo"), "runs", "*.json")
      ].then { |paths| File.binread(paths.fetch(0)) })

      assert_equal "terminal_replay", dispatch.decision.fetch("reason")
      assert_equal "running", run.fetch("status")
      assert_equal "attempt-replayed", run.fetch("attempt_id")
      assert_equal 1, run.fetch("retry_charge")
    end
  end

  def test_required_secret_uses_default_environment_availability_without_exposing_value
    with_env("MODULE_TEST_TOKEN" => "available") do
      with_runtime(secret_required: true) do |runtime|
        result = runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
        )

        assert result.launched?
        refute_includes JSON.generate(result.decision), "available"
        refute_includes JSON.generate(result.decision), "MODULE_TEST_TOKEN"
      end
    end
  end

  def test_retry_closes_when_disabled_and_records_capacity_retry_when_enabled
    with_runtime do |runtime|
      context = runtime.fetch(:dispatcher).send(:load_context, "demo", "task")
      hook_attempt = Hive::Modules::HookAttempt.build(
        project: "demo", project_id: "project-1", module_name: "demo",
        hook: context.fetch(:hook), selection: context.fetch(:selection),
        configuration: context.fetch(:configuration), event: runtime.fetch(:event)
      )
      runtime.fetch(:dispatcher).send(:persist_run, "demo", hook_attempt, runtime.fetch(:event))
      runtime.fetch(:store).disable("demo", now: NOW)

      assert_nil runtime.fetch(:dispatcher).retry(
        module_name: "demo", hook_attempt: hook_attempt,
        previous_attempt: PreviousAttempt.new("attempt-before", 0)
      )
      run = JSON.parse(File.binread(File.join(
        runtime.fetch(:store).runtime_path("demo"), "runs", "#{hook_attempt.run_id}.json"
      )))
      assert_equal "retry_closed", run.dig("retry", "reason")
    end

    capacity = Hive::Attempts::DispatchResult.new(
      status: :deferred, attempt: nil, receipt: nil, attach_descriptor: nil, reason: "capacity"
    )
    result_dispatcher = ResultDispatcher.new(capacity)
    with_runtime(attempt_dispatcher: result_dispatcher) do |runtime|
      context = runtime.fetch(:dispatcher).send(:load_context, "demo", "task")
      hook_attempt = Hive::Modules::HookAttempt.build(
        project: "demo", project_id: "project-1", module_name: "demo",
        hook: context.fetch(:hook), selection: context.fetch(:selection),
        configuration: context.fetch(:configuration), event: runtime.fetch(:event)
      )
      runtime.fetch(:dispatcher).send(:persist_run, "demo", hook_attempt, runtime.fetch(:event))

      result = runtime.fetch(:dispatcher).retry(
        module_name: "demo", hook_attempt: hook_attempt,
        previous_attempt: PreviousAttempt.new("attempt-before", 2)
      )
      run = JSON.parse(File.binread(File.join(
        runtime.fetch(:store).runtime_path("demo"), "runs", "#{hook_attempt.run_id}.json"
      )))
      assert_equal capacity, result
      assert_equal "retrying", run.fetch("status")
      assert_equal "pending", run.dig("retry", "status")
      assert_equal "capacity_blocked", run.dig("retry", "reason")
      assert_equal 3, run.dig("retry", "charge")
      assert_equal 3, result_dispatcher.calls.fetch(0).fetch(:retry_charge)
      assert_equal(
        "launch_handoff_failed",
        runtime.fetch(:dispatcher).send(
          :deferred_reason, "launch_handoff_failed"
        )
      )

      failed = Hive::Attempts::DispatchResult.new(
        status: :deferred, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: "provider"
      )
      runtime.fetch(:dispatcher).send(
        :update_run, "demo", hook_attempt, failed, nil, retry_charge: 3
      )
      run = JSON.parse(File.binread(File.join(
        runtime.fetch(:store).runtime_path("demo"),
        "runs", "#{hook_attempt.run_id}.json"
      )))
      assert_equal "failed", run.fetch("status")
      refute run.key?("retry")
    end
  end

  def test_admission_predicate_errors_fail_closed_before_state_mutation
    with_runtime do |runtime|
      result = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event),
        admission_open: -> { raise IOError, "shutdown state unavailable" }
      )

      assert_nil result
      assert_empty runtime.fetch(:attempt_store).scan.records
      assert_empty runtime.fetch(:journal).all
    end
  end

  def test_shutdown_after_run_persistence_closes_run_before_attempt_dispatch
    with_runtime do |runtime|
      runs = File.join(runtime.fetch(:store).runtime_path("demo"), "runs", "*.json")
      admission_open = -> { Dir[runs].empty? }

      result = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event),
        admission_open: admission_open
      )

      assert_nil result
      assert_empty runtime.fetch(:attempt_store).scan.records
      run = JSON.parse(File.binread(Dir[runs].fetch(0)))
      assert_equal "failed", run.fetch("status")
      assert_equal "shutdown_closed", run.dig("retry", "reason")
    end
  end

  def test_malformed_hook_state_lock_failure_and_foreign_event_fail_closed
    with_runtime do |runtime|
      hooks_path = File.join(runtime.fetch(:store).runtime_path("demo"), "hooks.json")
      File.write(hooks_path, "{bad")
      error = assert_raises(Hive::ConfigError) do
        runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
        )
      end
      assert_match(/runtime state is malformed/, error.message)
    end

    with_runtime do |runtime|
      foreign = runtime.fetch(:event).merge("project_id" => "another-project")
      assert_raises(Hive::ConfigError) do
        runtime.fetch(:dispatcher).dispatch_event(foreign)
      end

      original_open = File.method(:open)
      File.define_singleton_method(:open) { |*| raise Errno::EACCES, "denied" }
      begin
        error = assert_raises(Hive::ConfigError) do
          runtime.fetch(:dispatcher).dispatch(
            module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
          )
        end
        assert_match(/admission lock is unavailable/, error.message)
      ensure
        File.define_singleton_method(:open, original_open)
      end
    end

    with_runtime do |runtime|
      original_open = File.method(:open)
      File.define_singleton_method(:open) { |*| raise Errno::EACCES, "denied" }
      begin
        error = assert_raises(Hive::ConfigError) do
          runtime.fetch(:dispatcher).send(
            :with_hook_lock, "demo", "task"
          ) { flunk "lock failure must not yield" }
        end
        assert_match(/admission lock is unavailable/, error.message)
      ensure
        File.define_singleton_method(:open, original_open)
      end
    end
  end

  def test_missing_and_structurally_malformed_hook_state_are_distinguished
    with_runtime do |runtime|
      hooks_path = File.join(runtime.fetch(:store).runtime_path("demo"), "hooks.json")
      FileUtils.rm_f(hooks_path)
      missing = runtime.fetch(:dispatcher).dispatch(
        module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
      )
      assert_equal "hook_disabled", missing.decision.fetch("reason")
    end

    with_runtime do |runtime|
      hooks_path = File.join(runtime.fetch(:store).runtime_path("demo"), "hooks.json")
      File.write(
        hooks_path,
        Hive::WorkflowPackage::CanonicalJSON.generate("schema_version" => 1, "hooks" => [])
      )
      assert_raises(Hive::ConfigError) do
        runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: runtime.fetch(:event)
        )
      end
    end
  end

  def test_default_clock_is_used_for_decision_receipts
    with_runtime do |runtime|
      dispatcher = Hive::Modules::Dispatcher.new(
        store: runtime.fetch(:store), attempt_store: runtime.fetch(:attempt_store),
        attempt_dispatcher: runtime.fetch(:attempt_dispatcher),
        project_id: "project-1", project: "demo", decision_journal: runtime.fetch(:journal)
      )
      result = dispatcher.dispatch(
        module_name: "missing", hook_id: "task", event: runtime.fetch(:event)
      )
      refute_nil result.decision.fetch("evaluated_at")
    end
  end

  private

  def with_runtime(attempt_dispatcher: nil, secret_required: false)
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [ "0 * * * *" ],
          "events" => [ "task.completed" ], "concurrency" => "drop"
        }
      ]
      package = File.join(root, "package")
      settings = [
        { "name" => "mode", "type" => "enum", "required" => true,
          "default" => "safe", "values" => %w[safe fast] },
        { "name" => "api_token", "type" => "secret", "required" => secret_required,
          "secret" => true }
      ]
      resolution, descriptor = write_module_package(package, hooks: hooks, settings: settings)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: {
          "mode" => "safe", "api_token" => secret_required ? "MODULE_TEST_TOKEN" : nil
        }, hooks: { "task" => true },
        grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      attempt_store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      launcher = Launcher.new
      attempt_dispatcher ||= Hive::Attempts::Dispatcher.new(
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
        attempt_dispatcher: attempt_dispatcher, ledger: ledger, journal: journal,
        dispatcher: dispatcher
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
