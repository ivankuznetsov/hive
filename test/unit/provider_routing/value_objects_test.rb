require_relative "../../test_helper"
require "hive/provider_routing/circuit"
require "hive/provider_routing/decision"
require "hive/provider_routing/request"
require "hive/provider_routing/signal"

class ProviderRoutingValueObjectsTest < Minitest::Test
  Candidate = Data.define(:provider, :model, :agent, :effort)

  def test_signal_requires_a_model_for_model_scope_and_normalizes_time_strings
    assert_raises(ArgumentError) { signal(scope: "model", model: nil) }

    parsed = signal(reset_at: "2026-07-16T12:30:00Z")
    invalid = signal(reset_at: "not-a-time")

    assert_equal Time.utc(2026, 7, 16, 12, 30), parsed.reset_at
    assert_nil invalid.reset_at
  end

  def test_circuit_parse_time_rejects_malformed_values
    assert_nil Hive::ProviderRouting::Circuit.parse_time("not-a-time")
  end

  def test_request_normalizes_hash_exclusions
    candidate = Candidate.new(provider: "claude", model: "opus", agent: "claude", effort: "high")
    request = Hive::ProviderRouting::Request.new(
      configuration: Object.new,
      checkpoint: "generation-1",
      exclusions: [ { "provider" => "claude", "model" => "opus" } ]
    )

    assert request.excluded?(candidate)
    assert_equal "context_length", request.exclusions.first.reason
  end

  def test_wait_decision_exposes_nil_safe_candidate_accessors
    decision = Hive::ProviderRouting::Decision.new(
      status: :wait, attempt_id: "a1", reason: "closed",
      wait_reason: "limits_reached", rejections: [], explanation: "wait"
    )

    assert_nil decision.agent
    assert_nil decision.provider
    assert_nil decision.model
    assert_nil decision.effort
  end

  private

  def signal(scope: "provider", model: nil, reset_at: nil)
    Hive::ProviderRouting::Signal.new(
      provider: "claude", model: model, failure_class: "quota", scope: scope,
      reset_at: reset_at, safe_summary: "quota", fingerprint: "fp", evidence_ref: "log"
    )
  end
end
