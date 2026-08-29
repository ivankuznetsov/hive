require "test_helper"
require "hive/attempts/finalization_maintenance"
require "hive/provider_health/attempt_observer"

class ProviderHealthAttemptLifecycleTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)
  CAPABILITY = "c" * 64

  def test_terminal_archival_waits_for_idempotent_health_acknowledgement
    with_tmp_dir do |root|
      attempts = Hive::Attempts::Repository.new(
        root: File.join(root, "attempts"), migrate: true
      )
      terminal = terminal_attempt(attempts)
      health = Hive::ProviderHealth::Store.new(
        root: File.join(root, "health"),
        clock: -> { NOW },
        attempt_reader: lambda do |id|
          record = attempts.fetch(id)
          record && {
            "attempt_id" => record.attempt_id,
            "task_generation" => record.task_generation,
            "ownership_fence" => record.ownership_generation,
            "state" => record.state
          }
        end
      )
      factory = -> { Hive::ProviderHealth::AttemptObserver.new(store: health) }
      maintenance = Hive::Attempts::FinalizationMaintenance.new(
        store: attempts,
        provider_health_observer_factory: factory,
        delivery_pending: ->(_record) { false }
      )

      assert maintenance.prepare(terminal)
      pending = attempts.publication(terminal.attempt_id)
      assert_equal false, pending.dig("consumers", "provider_health")
      refute maintenance.promote(terminal)

      assert maintenance.acknowledge_provider_health(terminal)
      restarted = Hive::Attempts::FinalizationMaintenance.new(
        store: attempts,
        provider_health_observer_factory: factory,
        delivery_pending: ->(_record) { false }
      )
      assert restarted.acknowledge_provider_health(terminal)
      assert_equal 1, health.inspect_scope(model_scope).generation

      restarted.acknowledge(terminal, :journal)
      restarted.acknowledge(terminal, :request_delivery)
      assert restarted.promote(terminal)
      assert_nil attempts.fetch_hot(terminal.attempt_id)
      assert attempts.fetch(terminal.attempt_id)
    end
  end

  private

  def terminal_attempt(store)
    launching = store.create_launching(
      attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
      task_generation: "generation-1", ownership_generation: "generation-1",
      task_input_epoch: 1, progress_token: "progress", provider: "codex",
      routing: routing, worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CAPABILITY),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    )
    claimed = store.claim(
      launching, owner: { "pid" => Process.pid }, claim_capability: CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    File.binwrite(store.log_archive.hot_path(running.attempt_id), "")
    @reference = Hive::Attempts::OutputReference.build(
      store.log_archive.hot_path(running.attempt_id), root: store.root
    )
    store.terminalize(
      running, outcome: "failed", exit_status: 70,
      final_checkpoint: running.checkpoint, output_references: [],
      log_reference: reference, provider_evidence: evidence,
      now: NOW + 3
    )
  end

  def routing
    {
      "mode" => "explicit", "policy_digest" => "a" * 64,
      "decision" => {
        "decision_id" => "decision-1", "policy_digest" => "a" * 64,
        "decided_at" => NOW.iso8601(6), "exclusions" => []
      },
      "route" => {
        "route_id" => "account-a/model-a", "provider_account_id" => "account-a",
        "adapter" => "codex", "launch_binding_id" => "default",
        "model" => "model-a", "effort" => "high"
      },
      "circuit_generations" => [
        { "scope" => provider_scope.to_h, "journal_epoch" => 0, "observed_generation" => 0 },
        { "scope" => model_scope.to_h, "journal_epoch" => 0, "observed_generation" => 0 }
      ],
      "probe_bindings" => []
    }
  end

  def evidence
    Hive::ProviderHealth::Evidence.new(
      scope: model_scope, failure_class: "model_capacity",
      provenance: "codex_jsonl_transport", route: route,
      reset_hint_seconds: 30, source_reference: reference,
      attempt_id: "attempt-1"
    ).to_h
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "account-a/model-a", account_id: "account-a", adapter: "codex",
      launch_binding_id: "default", model_id: "model-a"
    )
  end

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "account-a")
  end

  def model_scope
    @model_scope ||= Hive::ProviderHealth::Scope.model(
      account_id: "account-a", model_id: "model-a"
    )
  end

  def reference
    @reference || raise("attempt log reference is unavailable")
  end
end
