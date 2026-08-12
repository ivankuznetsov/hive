require_relative "../test_helper"
require "hive/attempts/dispatcher"
require "hive/attempts/finalization_maintenance"
require "hive/daemon/recovery_coordinator"
require "hive/provider_health/attempt_observer"
require "hive/provider_health/store"
require "hive/provider_routing"

class ProviderRoutingRecoveryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)
  CAPABILITY = "c" * 64
  Task = Data.define(:id, :slug, :folder, :state_file, :stage_index, :stage_name)
  Row = Data.define(
    :project, :slug, :folder, :state_file, :stage, :workflow, :marker,
    :marker_attrs, :state_file_mtime, :live_task_lock, :attempt_id,
    :task_generation, :suggested_command
  )

  class Launcher
    attr_reader :launched

    def initialize
      @launched = []
    end

    def preflight! = true

    def launch(record, claim_capability:)
      @launched << [ record, claim_capability ]
      { "claimed" => true }
    end
  end

  def test_failed_a_health_acknowledges_before_one_recovery_successor_selects_b
    with_tmp_dir do |root|
      task = build_task(root)
      attempts = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      health = health_store(root, attempts)
      launcher = Launcher.new
      ids = %w[attempt-a attempt-b].each
      dispatcher = Hive::Attempts::Dispatcher.new(
        store: attempts, launcher: launcher,
        limits: { max_global: 3, max_per_project: 3, max_daily: 50 },
        clock: -> { NOW }, id_generator: -> { ids.next },
        decision_id_generator: -> { SecureRandom.uuid },
        capability_generator: -> { CAPABILITY }, health_store: health,
        task_resolver: ->(_request) { task },
        routing_policy_resolver: ->(_task, _stage) { policy }
      )
      dispatcher.define_singleton_method(:provider_for) { |_task| "codex" }
      first = dispatcher.dispatch(
        task: task, project: "demo", intended_stage: "4-execute",
        argv: %w[hive run routed-task], request_id: "initial-request",
        provider: "codex", routing_policy: policy, now: NOW
      )
      terminal = terminalize_provider_failure(attempts, launcher, first)
      maintenance = Hive::Attempts::FinalizationMaintenance.new(
        store: attempts,
        provider_health_observer_factory: lambda do
          Hive::ProviderHealth::AttemptObserver.new(store: health)
        end
      )
      assert maintenance.prepare(terminal)
      assert maintenance.acknowledge_provider_health(terminal)
      assert_equal "open", health.inspect_scope(provider_scope("account-a")).circuit.automatic_state

      marker = provider_failure_marker(task, terminal)
      row = recovery_row(task, marker)
      coordinator = Hive::Daemon::RecoveryCoordinator.new(
        state_home: root, task_resolver: ->(**_attributes) { task },
        safety: ->(_observation) { [ true, "safe" ] }, attempt_store: attempts
      )
      queued = coordinator.request(
        row: row, requestor: "healer", request_id: "caller-id", now: NOW
      )
      recovery = Hive::Daemon::DispatchRequestQueue.fetch(
        queued.request_id, state_home: root
      )

      assert_equal "queued", queued.status
      assert_equal 1, queued.retry_count
      assert_equal terminal.attempt_id, recovery.predecessor_attempt_id
      assert_equal terminal.attempt_id,
                   recovery.recovery.dig("source_receipt", "attempt_id")
      resumed = coordinator.resume(request: recovery, row: row, now: NOW)
      assert_equal "cleared", resumed.phase
      assert Hive::Markers.current(task.state_file).none?

      successor = dispatcher.dispatch_request(recovery, now: NOW + 1)

      assert_equal :accepted, successor.status
      assert_equal "account-b/model-b", successor.decision.route.id
      assert_equal terminal.attempt_id, successor.attempt["predecessor_attempt_id"]
      assert_equal terminal.task_generation, successor.attempt.task_generation
      assert_equal policy.digest, successor.attempt["routing"].fetch("policy_digest")
      assert_equal 1, successor.attempt["retry_charge"]
      assert_equal 2, attempts.scan.records.size
      assert_equal 1,
                   Hive::Daemon::DispatchRequestQueue.pending(state_home: root).size
      assert_equal 1, recovery.recovery.fetch("retry_count")
    end
  end

  private

  def build_task(root)
    folder = File.join(root, "task")
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "task.md")
    File.write(state_file, "# Routed task\n")
    Task.new(
      id: 42, slug: "routed-task", folder: folder, state_file: state_file,
      stage_index: 4, stage_name: "execute"
    )
  end

  def health_store(root, attempts)
    Hive::ProviderHealth::Store.new(
      root: File.join(root, "provider-health"), clock: -> { NOW },
      attempt_reader: lambda do |attempt_id|
        record = attempts.fetch(attempt_id)
        record && {
          "attempt_id" => record.attempt_id,
          "task_generation" => record.task_generation,
          "ownership_fence" => record.ownership_generation,
          "state" => record.state,
          "probe_bindings" => record["routing"].fetch("probe_bindings", [])
        }
      end
    )
  end

  def terminalize_provider_failure(store, launcher, result)
    capability = launcher.launched.find do |record, _token|
      record.attempt_id == result.attempt.attempt_id
    end.fetch(1)
    claimed = store.claim(
      result.attempt, owner: { "pid" => Process.pid },
      claim_capability: capability, first_heartbeat_timeout_sec: 30,
      now: NOW + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    reference = {
      "path" => "logs/attempt-a.frames", "size" => 0,
      "sha256" => Digest::SHA256.hexdigest("")
    }
    route = Hive::ProviderHealth::RouteIdentity.new(
      route_id: "account-a/model-a", account_id: "account-a", adapter: "codex",
      launch_binding_id: "binding-a", model_id: "model-a"
    )
    evidence = Hive::ProviderHealth::Evidence.new(
      scope: provider_scope("account-a"), failure_class: "account_quota",
      provenance: "codex_jsonl_transport", route: route,
      reset_hint_seconds: 3_600, source_reference: reference,
      attempt_id: result.attempt.attempt_id
    )
    store.terminalize(
      running, outcome: "failed", exit_status: 70,
      final_checkpoint: running.checkpoint, output_references: [],
      log_reference: reference, provider_evidence: evidence.to_h,
      now: NOW + 3
    )
  end

  def provider_failure_marker(task, terminal)
    route = terminal["routing"].fetch("route")
    Hive::Markers.set(
      task.state_file, :error,
      reason: "provider_route_failed", marker_id: "provider-marker",
      attempt_id: terminal.attempt_id,
      task_generation: terminal.task_generation,
      ownership_generation: terminal.ownership_generation,
      task_input_epoch: terminal.task_input_epoch,
      provider_account_id: route.fetch("provider_account_id"),
      route_id: route.fetch("route_id")
    )
    File.utime(NOW - Hive::AgentLimit.retry_cooldown_sec,
               NOW - Hive::AgentLimit.retry_cooldown_sec, task.state_file)
    Hive::Markers.current(task.state_file)
  end

  def recovery_row(task, marker)
    Row.new(
      project: "demo", slug: task.slug, folder: task.folder,
      state_file: task.state_file, stage: "4-execute", workflow: "coding",
      marker: marker.name.to_s, marker_attrs: marker.attrs,
      state_file_mtime: NOW - Hive::AgentLimit.retry_cooldown_sec,
      live_task_lock: false, attempt_id: marker.attrs["attempt_id"],
      task_generation: marker.attrs["task_generation"],
      suggested_command: "hive run routed-task --stage 4-execute --project demo --json"
    )
  end

  def policy
    @policy ||= Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [
        route("account-a", "model-a", "codex", "binding-a", 0),
        route("account-b", "model-b", "claude", "binding-b", 1)
      ],
      requirements: Hive::ProviderRouting::Requirements.empty, pin: nil,
      account_policy: {
        "account-a" => account("codex", "binding-a", "model-a"),
        "account-b" => account("claude", "binding-b", "model-b")
      }
    )
  end

  def route(account_id, model, adapter, binding, order)
    Hive::ProviderRouting::Route.new(
      id: "#{account_id}/#{model}", account: account_id, adapter: adapter,
      launch_binding: binding, model: model, effort: "high", order: order,
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell], "permissions" => %w[read]
      }
    )
  end

  def account(adapter, binding, model)
    {
      "adapter" => adapter, "launch_binding" => binding,
      "models" => [ model ], "max_concurrent" => 1,
      "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
    }
  end

  def provider_scope(account_id)
    Hive::ProviderHealth::Scope.provider_account(account_id: account_id)
  end
end
