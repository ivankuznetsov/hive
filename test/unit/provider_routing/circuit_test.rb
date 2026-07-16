require_relative "../../test_helper"
require "hive/provider_routing/circuit"
require "hive/provider_routing/signal"

class ProviderRoutingCircuitTest < Minitest::Test
  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def setup
    @account = Hive::ProviderRouting::Account.new(
      key: "claude-main",
      adapter: "claude",
      max_concurrent: nil,
      cooldown_sec: Hive::ProviderRouting::DEFAULT_COOLDOWNS,
      backoff_cap_sec: 7200
    )
  end

  def test_timed_signal_opens_and_reset_evidence_wins
    reset_at = NOW + 1800
    state = Hive::ProviderRouting::Circuit.open(
      state: Hive::ProviderRouting::Circuit.closed,
      signal: signal("session_limit", reset_at: reset_at),
      account: @account,
      now: NOW,
      generation: 1
    )

    assert_equal "open", state.fetch("state")
    assert_equal reset_at.iso8601, state.fetch("retry_at")
    refute state.fetch("indefinite")
    assert_equal 1, state.fetch("generation")
  end

  def test_past_reset_hint_uses_default_cooldown
    state = Hive::ProviderRouting::Circuit.open(
      state: Hive::ProviderRouting::Circuit.closed,
      signal: signal("rate_limit", reset_at: NOW - 1),
      account: @account,
      now: NOW,
      generation: 1
    )

    assert_equal (NOW + 300).iso8601, state.fetch("retry_at")
  end

  def test_administrative_signal_opens_indefinitely
    state = Hive::ProviderRouting::Circuit.open(
      state: Hive::ProviderRouting::Circuit.closed,
      signal: signal("auth"),
      account: @account,
      now: NOW,
      generation: 1
    )

    assert state.fetch("indefinite")
    assert_nil state["retry_at"]
    refute Hive::ProviderRouting::Circuit.probe_available?(state, now: NOW + 100_000)
  end

  def test_failed_probe_reopens_with_capped_exponential_backoff
    opened = Hive::ProviderRouting::Circuit.open(
      state: Hive::ProviderRouting::Circuit.closed,
      signal: signal("quota"), account: @account, now: NOW, generation: 1
    )
    claimed = Hive::ProviderRouting::Circuit.claim_probe(
      state: opened, attempt_id: "attempt-1", owner: "test", now: NOW + 3600, generation: 2
    )
    reopened = Hive::ProviderRouting::Circuit.open(
      state: claimed,
      signal: signal("quota"), account: @account, now: NOW + 3600,
      generation: 3, probe_failure: true
    )

    assert_equal 1, reopened.fetch("backoff_count")
    assert_equal (NOW + 3600 + 7200).iso8601, reopened.fetch("retry_at")
    assert_nil reopened["probe"]
  end

  private

  def signal(failure_class, reset_at: nil)
    Hive::ProviderRouting::Signal.new(
      provider: "claude-main", model: nil, failure_class: failure_class,
      scope: "provider", reset_at: reset_at, safe_summary: failure_class,
      fingerprint: "fp", evidence_ref: "logs/test.log"
    )
  end
end
