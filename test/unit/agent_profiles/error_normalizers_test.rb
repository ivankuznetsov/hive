require_relative "../../test_helper"
require "hive/agent_profiles/error_normalizers"

class AgentProfilesErrorNormalizersTest < Minitest::Test
  def test_claude_session_limit_is_timed_provider_signal
    signal = normalize(:claude, "You've hit your session limit · resets 8pm (Europe/London)")

    assert_equal "session_limit", signal.failure_class
    assert_equal "provider", signal.scope
    assert_equal "claude-main", signal.provider
    assert_nil signal.reset_at
  end

  def test_codex_quota_auth_and_context_are_distinct
    quota = normalize(:codex, '{"type":"error","message":"insufficient_quota"}')
    auth = normalize(:codex, '{"error":{"code":"invalid_api_key","message":"Unauthorized"}}')
    context = normalize(:codex, "maximum context length exceeded", model: "gpt-5")

    assert_equal [ "quota", "provider" ], [ quota.failure_class, quota.scope ]
    assert_equal [ "auth", "provider" ], [ auth.failure_class, auth.scope ]
    assert_equal [ "context_length", "task" ], [ context.failure_class, context.scope ]
  end

  def test_pi_openrouter_402_credit_and_429_rate_limit
    credit = normalize(:pi, "OpenRouter HTTP 402: insufficient credits")
    rate = normalize(:pi, "OpenRouter response status 429: Too Many Requests")

    assert_equal "credit", credit.failure_class
    assert_equal "rate_limit", rate.failure_class
  end

  def test_grok_credit_and_auth_examples
    credit = normalize(:grok, '{"status":402,"error":"credit balance exhausted"}')
    auth = normalize(:grok, "xAI authentication failed: invalid API key")

    assert_equal "credit", credit.failure_class
    assert_equal "auth", auth.failure_class
    assert credit.timed?
    assert auth.administrative?
  end

  def test_billing_configuration_is_indefinite_not_credit
    signal = normalize(:pi, "HTTP 402: billing account not configured; payment method required")

    assert_equal "billing_configuration", signal.failure_class
    assert signal.administrative?
  end

  def test_explicit_model_evidence_produces_model_scope
    signal = normalize(
      :codex,
      '{"error":{"code":"insufficient_quota","model_scope":true}}',
      model: "gpt-5"
    )

    assert_equal "model", signal.scope
    assert_equal "gpt-5", signal.model
  end

  def test_ambiguous_model_wording_stays_provider_scoped
    signal = normalize(:codex, "quota exceeded while choosing a model", model: "gpt-5")

    assert_equal "provider", signal.scope
  end

  def test_reset_hint_is_normalized_when_valid
    signal = normalize(:codex, '{"error":{"code":"rate_limit","retry_after":120}}')

    assert_in_delta Time.now.utc.to_f + 120, signal.reset_at.to_f, 3
  end

  def test_success_output_and_false_positive_prose_do_not_open_circuits
    success = normalizer(:claude).call(**context("usage limit reached", success: true))
    prose = normalize(:claude, "Implemented a scroll limit reached indicator")

    assert_nil success
    assert_equal "unknown", prose.failure_class
    refute prose.circuit_worthy?
  end

  def test_timeout_network_and_unknown_are_non_circuit_signals
    timeout = normalizer(:codex).call(**context("", timed_out: true))
    network = normalize(:grok, "connection reset by peer")
    unknown = normalize(:pi, "novel provider failure 987")

    assert_equal %w[timeout network unknown], [ timeout.failure_class, network.failure_class, unknown.failure_class ]
    refute timeout.circuit_worthy?
    refute network.circuit_worthy?
    refute unknown.circuit_worthy?
  end

  def test_signal_contains_safe_summary_and_fingerprint_not_raw_evidence
    raw = "invalid API key secret-value-123"
    signal = normalize(:grok, raw)

    assert_equal "grok authentication failure", signal.safe_summary
    assert_match(/\Asha256:[0-9a-f]{64}\z/, signal.fingerprint)
    refute_includes signal.to_h.values.map(&:to_s).join(" "), "secret-value-123"
    assert_equal "logs/adapter.log#tail", signal.evidence_ref
  end

  private

  def normalize(adapter, evidence, model: nil)
    normalizer(adapter).call(**context(evidence, model: model))
  end

  def normalizer(adapter)
    Hive::AgentProfiles::ErrorNormalizers.const_get(adapter.to_s.upcase)
  end

  def context(evidence, model: nil, success: false, timed_out: false)
    {
      evidence: evidence,
      exit_code: success ? 0 : 1,
      timed_out: timed_out,
      model: model,
      provider: "claude-main",
      evidence_ref: "logs/adapter.log#tail",
      success: success
    }
  end
end
