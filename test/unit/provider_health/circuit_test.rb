require_relative "../../test_helper"
require "hive/provider_health/circuit"
require "hive/provider_health/event"

class ProviderHealthCircuitTest < Minitest::Test
  def test_provider_and_model_scopes_are_independent
    provider = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    model = Hive::ProviderHealth::Circuit.closed(scope: model_scope)

    provider = open_event(provider, id: "provider-open").apply(provider)

    assert_equal "open", provider.effective_state(now: fixture_time(1))
    assert_equal "closed", model.effective_state(now: fixture_time(1))
    assert_equal 1, provider.generation
    assert_equal 0, model.generation
  end

  def test_half_open_is_a_read_time_view_and_does_not_advance_generation
    circuit = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    circuit = open_event(circuit, id: "open", eligible_at: fixture_time(2)).apply(circuit)

    assert_equal "open", circuit.effective_state(now: fixture_time(1))
    assert_equal "half_open", circuit.effective_state(now: fixture_time(2))
    assert circuit.eligible?(now: fixture_time(2))
    assert_equal 1, circuit.generation
  end

  def test_manual_block_is_orthogonal_to_automatic_state
    circuit = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    circuit = open_event(circuit, id: "open").apply(circuit)
    blocked = event(
      circuit,
      kind: "manual_blocked",
      id: "block",
      payload: {
        "manual_block" => {
          "actor" => "operator",
          "reason" => "maintenance",
          "blocked_at" => fixture_time(0).iso8601(6)
        },
        "audit" => audit("block", 2)
      }
    ).apply(circuit)
    unblocked = event(
      blocked,
      kind: "manual_unblocked",
      id: "unblock",
      payload: { "manual_block" => nil, "audit" => audit("unblock", 3) }
    ).apply(blocked)

    assert_equal "manual_block", blocked.effective_state(now: fixture_time(0))
    assert_equal "open", unblocked.effective_state(now: fixture_time(0))
    assert_equal "open", unblocked.automatic_state
    assert_equal 3, unblocked.generation
  end

  def test_probe_claim_and_close_require_distinct_generations
    circuit = Hive::ProviderHealth::Circuit.closed(scope: model_scope)
    circuit = open_event(circuit, id: "open", eligible_at: fixture_time(0)).apply(circuit)
    binding = Hive::ProviderHealth::ProbeBinding.new(
      scope: model_scope,
      journal_epoch: 0,
      observed_generation: 1,
      claim_generation: 2,
      attempt_id: "attempt-1",
      task_generation: "task-generation-1",
      ownership_fence: "fence-1"
    )
    claimed = event(
      circuit,
      kind: "probe_claimed",
      id: "claim",
      payload: { "probe" => binding.to_h }
    ).apply(circuit)
    closed = event(
      claimed,
      kind: "probe_closed",
      id: "close",
      payload: { "receipt_identity" => digest("receipt") }
    ).apply(claimed)

    assert_equal "probe_owned", claimed.effective_state(now: fixture_time(3))
    assert_equal 2, claimed.generation
    assert_equal "closed", closed.effective_state(now: fixture_time(3))
    assert_equal 3, closed.generation
    assert_nil closed.evidence
    assert_nil closed.probe
  end

  def test_nonmutating_rejection_preserves_generation
    circuit = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    rejected = Hive::ProviderHealth::Event.new(
      event_id: "rejected",
      sequence: 1,
      scope: provider_scope,
      journal_epoch: 0,
      kind: "evidence_rejected",
      occurred_at: fixture_time(0),
      idempotency_key: digest("rejected"),
      expected_generation: 0,
      previous_generation: 0,
      resulting_generation: 0,
      payload: { "reason" => "fenced_attempt" }
    ).apply(circuit)

    assert_equal 0, rejected.generation
    assert_equal "closed", rejected.automatic_state
  end

  def test_circuit_round_trip_and_invalid_compositions
    closed = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)

    assert_equal closed.to_h, Hive::ProviderHealth::Circuit.from_h(closed.to_h).to_h
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      closed.with(eligible_at: fixture_time(1))
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      closed.with(automatic_state: "open")
    end
  end

  def test_event_validation_rejects_schema_generation_scope_and_payload_drift
    circuit = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    valid = rejection_event(circuit).to_h

    assert_raises(Hive::ProviderHealth::Unavailable) do
      Hive::ProviderHealth::Event.from_h({})
    end
    invalid = valid.merge("payload" => { "reason" => "not-allowlisted" })
    assert_raises(Hive::ProviderHealth::Unavailable) do
      Hive::ProviderHealth::Event.from_h(invalid)
    end
    assert_raises(Hive::ProviderHealth::Unavailable) do
      rejection_event(circuit).apply(Hive::ProviderHealth::Circuit.closed(scope: model_scope))
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event_from(valid.merge("sequence" => "not-an-integer"))
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event_from(valid.merge("expected_generation" => 1))
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event_from(valid.merge("resulting_generation" => 1))
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event_from(valid.merge("payload" => valid.fetch("payload").merge("extra" => true)))
    end
  end

  def test_event_validation_rejects_mismatched_manual_probe_and_audit_payloads
    circuit = Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    valid_audit = audit("block", 1)
    block = {
      "actor" => "different-operator", "reason" => "maintenance",
      "blocked_at" => fixture_time(0).iso8601(6)
    }
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event(circuit, kind: "manual_blocked", id: "block", payload: {
        "manual_block" => block, "audit" => valid_audit
      })
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event(
        circuit, kind: "evidence_rejected", id: "bad-rejection",
        payload: { "reason" => "unknown" }
      )
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event(circuit, kind: "probe_claimed", id: "bad-probe", payload: {
        "probe" => { "scope" => provider_scope.to_h }
      })
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event(circuit, kind: "manual_blocked", id: "bad-block", payload: {
        "manual_block" => { "actor" => "operator" }, "audit" => valid_audit
      })
    end

    wrong_audit = audit("block", 2).merge("event_id" => "wrong-event")
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      event(circuit, kind: "manual_blocked", id: "block", payload: {
        "manual_block" => {
          "actor" => "operator", "reason" => "maintenance",
          "blocked_at" => fixture_time(0).iso8601(6)
        },
        "audit" => wrong_audit
      })
    end
  end

  private

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "codex-primary")
  end

  def model_scope
    @model_scope ||= Hive::ProviderHealth::Scope.model(
      account_id: "codex-primary", model_id: "gpt-5.6-sol"
    )
  end

  def open_event(circuit, id:, eligible_at: fixture_time(4))
    event(
      circuit,
      kind: "evidence_opened",
      id: id,
      payload: {
        "evidence" => evidence_hash(circuit.scope),
        "eligible_at" => eligible_at.iso8601(6)
      }
    )
  end

  def rejection_event(circuit)
    Hive::ProviderHealth::Event.new(
      event_id: "rejected", sequence: 1, scope: circuit.scope,
      journal_epoch: circuit.journal_epoch, kind: "evidence_rejected",
      occurred_at: fixture_time(0), idempotency_key: digest("rejected"),
      expected_generation: circuit.generation,
      previous_generation: circuit.generation,
      resulting_generation: circuit.generation,
      payload: { "reason" => "fenced_attempt" }
    )
  end

  def event_from(data)
    Hive::ProviderHealth::Event.new(
      event_id: data.fetch("event_id"), sequence: data.fetch("sequence"),
      scope: Hive::ProviderHealth.scope_from_h(data.fetch("scope")),
      journal_epoch: data.fetch("journal_epoch"), kind: data.fetch("kind"),
      occurred_at: data.fetch("occurred_at"), idempotency_key: data.fetch("idempotency_key"),
      expected_generation: data.fetch("expected_generation"),
      previous_generation: data.fetch("previous_generation"),
      resulting_generation: data.fetch("resulting_generation"), payload: data.fetch("payload")
    )
  end

  def evidence_hash(scope)
    Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: scope.model? ? "model_capacity" : "provider_outage",
      provenance: "codex_jsonl_transport",
      route: Hive::ProviderHealth::RouteIdentity.new(
        route_id: "codex-primary/gpt-5.6-sol",
        account_id: "codex-primary",
        adapter: "codex",
        launch_binding_id: "default",
        model_id: "gpt-5.6-sol"
      ),
      reset_hint_seconds: 300,
      source_reference: {
        "path" => "outputs/safe.json", "size" => 1, "sha256" => "a" * 64
      },
      attempt_id: "attempt-1"
    ).to_h
  end

  def event(circuit, kind:, id:, payload:)
    Hive::ProviderHealth::Event.new(
      event_id: id,
      sequence: circuit.last_event_id ? circuit.generation + 1 : 1,
      scope: circuit.scope,
      journal_epoch: circuit.journal_epoch,
      kind: kind,
      occurred_at: fixture_time(0),
      idempotency_key: digest(id),
      expected_generation: circuit.generation,
      previous_generation: circuit.generation,
      resulting_generation: circuit.generation + 1,
      payload: payload
    )
  end

  def audit(action, generation)
    {
      "actor" => "operator",
      "reason" => "maintenance",
      "target" => provider_scope.to_h,
      "action" => action,
      "occurred_at" => fixture_time(0).iso8601(6),
      "previous_state" => audit_state(generation - 1),
      "new_state" => audit_state(generation),
      "generation" => generation,
      "event_id" => action,
      "artifact_reference" => nil
    }
  end

  def audit_state(generation)
    {
      "automatic_state" => "open",
      "manual_blocked" => false,
      "probe_owned" => false,
      "generation" => generation,
      "journal_epoch" => 0
    }
  end

  def fixture_time(hour)
    Time.utc(2026, 8, 10, hour)
  end

  def digest(value)
    Hive::ProviderHealth.digest(value)
  end
end
