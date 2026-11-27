require "test_helper"
require "hive/babysitter/failure_classifier"

class BabysitterFailureClassifierTest < Minitest::Test
  def test_ignores_non_hashes_and_healthy_results
    assert_nil Hive::Babysitter::FailureClassifier.classify(nil)
    assert_nil Hive::Babysitter::FailureClassifier.classify("error")
    refute Hive::Babysitter::FailureClassifier.model_unsupported?(nil)

    healthy = {
      status: :ok,
      timed_out: false,
      final_message: "Fixed rate limit test for 429 Too Many Requests and 503 Service Unavailable"
    }
    assert_nil Hive::Babysitter::FailureClassifier.classify(healthy)
  end

  def test_model_unsupported_is_not_classified_as_a_limit_or_provider_hold
    by_reason = {
      status: :error,
      error_reason: Hive::ModelUnsupported::REASON,
      error_message: "model unsupported for codex: 'gpt-6-sol' is not available",
      provider_error: { kind: :provider_error, provider: :codex, message: "unsupported" }
    }
    by_provider_error = {
      status: :error,
      provider_error: {
        kind: :provider_error,
        provider: :codex,
        message: "The 'gpt-6-sol' model is not supported when using Codex with a ChatGPT account."
      }
    }

    assert Hive::Babysitter::FailureClassifier.model_unsupported?(by_reason)
    assert Hive::Babysitter::FailureClassifier.model_unsupported?(by_provider_error)
    assert_nil Hive::Babysitter::FailureClassifier.classify(by_reason)
    assert_nil Hive::Babysitter::FailureClassifier.classify(by_provider_error)
  end

  def test_classifies_structured_quota_and_rate_limit_failures
    cases = [
      [ { status: :error, timed_out: true, error_reason: "limits_reached", error_message: "limits reached for codex: wall" }, "limits_reached" ],
      [ { status: :error, limit_text: "You've hit your usage limit" }, "limits_reached" ],
      [ { status: :error, error_message: "limits reached for claude: wall" }, "limits_reached" ],
      [ { status: :error, provider_error: { kind: :provider_limit, provider: :pi, message: "credits exhausted" } }, "provider_limit" ],
      [ { status: :error, provider_error: { kind: :rate_limited, provider: :codex, message: "slow down" } }, "rate_limited" ],
      [ { status: :error, provider_error: { kind: :provider_error, status_code: 429, message: "throttled" } }, "rate_limited" ],
      [ { status: :error, provider_error: { kind: :provider_error, status_code: 402, message: "top up" } }, "provider_limit" ],
      [ { status: :error, provider_error: { kind: :provider_error, message: "You've hit your limit" } }, "limits_reached" ],
      [ { status: :error, provider_signal: { "failure_class" => "account_quota" } }, "account_quota" ],
      [ { status: :error, provider_signal: { failure_class: "provider_rate_limit" } }, "provider_rate_limit" ]
    ]

    cases.each do |result, expected_reason|
      classified = Hive::Babysitter::FailureClassifier.classify(result)
      refute_nil classified, "expected limit classification for #{result.inspect}"
      assert_equal :limits_reached, classified.outcome
      assert_equal expected_reason, classified.reason
    end
  end

  def test_classifies_unstructured_quota_usage_cap_credit_and_429_messages
    messages = [
      "You've hit your limit \u00b7 resets 8pm (Europe/London)",
      "You have reached your usage cap. Try again later.",
      "Your credit balance is too low to access the Anthropic API.",
      "You have exhausted your capacity on this model. Your quota will reset after 4h23m.",
      "API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"throttled\"}}",
      "HTTP 402 Payment Required",
      "Error: RESOURCE_EXHAUSTED: quota exceeded",
      "Insufficient credits remaining on your account",
      "You exceeded your current quota, please check your plan"
    ]

    messages.each do |message|
      classified = Hive::Babysitter::FailureClassifier.classify(
        status: :error,
        error_message: "exit_code=1",
        final_message: "\n#{message}\n"
      )
      refute_nil classified, "expected :limits_reached for #{message.inspect}"
      assert_equal :limits_reached, classified.outcome, message
      assert_equal "limits_reached", classified.reason, message
      assert_equal message, classified.message, "diagnostic should prefer the real error over exit_code=1"
      assert_equal message, classified.retry_after_text
    end
  end

  def test_classifies_structured_operational_and_provider_errors
    cases = [
      [ { status: :error, preflight_failed: true, error_message: "preflight failed: codex (ENOENT)" }, "preflight_failed" ],
      [ { status: :error, error_reason: "provider_error", error_message: "529 Overloaded" }, "provider_error" ],
      [ { status: :error, error_reason: "provider_route_failed", error_message: "admitted route failed" }, "provider_route_failed" ],
      [ { status: :error, error_reason: "provider_route_preflight_failed", error_message: "preflight failed" }, "provider_route_preflight_failed" ],
      [ { status: :error, error_reason: "authentication_failure", error_message: "API key expired" }, "authentication_failure" ],
      [ { status: :error, error_reason: "process_cleanup_failed", error_message: "cleanup timed out" }, "process_cleanup_failed" ],
      [ { status: :error, provider_error: { kind: :provider_error, provider: :pi, status_code: 502, message: "bad gateway" } }, "provider_error" ],
      [ { status: :error, provider_signal: { "failure_class" => "provider_outage" } }, "provider_outage" ],
      [ { status: :error, provider_signal: { "failure_class" => "" } }, "provider_signal" ]
    ]

    cases.each do |result, expected_reason|
      classified = Hive::Babysitter::FailureClassifier.classify(result)
      refute_nil classified, "expected provider_error classification for #{result.inspect}"
      assert_equal :provider_error, classified.outcome
      assert_equal expected_reason, classified.reason
    end
  end

  def test_classifies_unstructured_capacity_overloaded_5xx_and_network_errors
    messages = [
      'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
      "The model is overloaded. Please try again later.",
      "Service temporarily unavailable",
      "MODEL_CAPACITY_EXHAUSTED: No capacity available for model gemini-3",
      "Our servers are experiencing high demand right now",
      "unexpected status 503 Service Unavailable",
      "502 Bad Gateway",
      "504 Gateway Timeout",
      "Upstream idle timeout exceeded",
      "stream disconnected before completion",
      "The server had an error while processing your request",
      "Error: read ECONNRESET",
      "connection reset by peer",
      "socket hang up",
      "temporary failure in name resolution"
    ]

    messages.each do |message|
      classified = Hive::Babysitter::FailureClassifier.classify(
        status: :error,
        error_message: "exit_code=1",
        final_message: message
      )
      refute_nil classified, "expected :provider_error for #{message.inspect}"
      assert_equal :provider_error, classified.outcome, message
      assert_equal "transient_provider_error", classified.reason, message
      assert_equal message, classified.message
    end

    upstream_timeout = Hive::Babysitter::FailureClassifier.classify(
      status: :timeout,
      timed_out: false,
      error_reason: "timeout",
      error_message: "{'code':504,'message':'Upstream idle timeout exceeded'}"
    )
    assert_equal :provider_error, upstream_timeout.outcome
    assert_equal "transient_provider_error", upstream_timeout.reason
  end

  def test_model_output_limit_is_not_classified_as_a_provider_outage
    result = {
      status: :error,
      error_reason: "model_output_limit",
      error_message: "agent response reached the model's maximum output tokens",
      provider_error: { kind: :model_output_limit, provider: :pi, message: "truncated" }
    }

    assert_nil Hive::Babysitter::FailureClassifier.classify(result)
  end

  def test_redacts_secrets_from_classified_diagnostic_message
    classified = Hive::Babysitter::FailureClassifier.classify(
      status: :error,
      error_reason: "provider_error",
      error_message: "401 Unauthorized: bad key sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"
    )

    assert_equal :provider_error, classified.outcome
    refute_includes classified.message, "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"
    assert_includes classified.message, "[REDACTED:anthropic_api_key]"
  end

  def test_does_not_misclassify_benign_chrome_or_genuine_pr_failures
    genuine_failures = [
      { status: :error, final_message: "tests failed" },
      { status: :error, error_message: "provider exited with status 2",
        final_message: "rmcp::transport::worker quit with fatal: AuthRequired" },
      { status: :error, final_message: "Included in your plan limits until Jun 22, then switch to usage credits to continue." },
      { status: :error, final_message: "Approaching session limit \u00b7 run /compact to continue" },
      { status: :error, final_message: "Run /status to see usage limits and account info" },
      { status: :error, final_message: "The viewport scrolls until the scroll limit is reached" },
      { status: :error, final_message: "missing rate limit on /api/upload" },
      { status: :error, final_message: "test_api_returns_500 failed: expected HTTP 200, got 500" },
      { status: :error, final_message: "ECONNREFUSED 127.0.0.1:5432" },
      { status: :timeout, timed_out: true },
      { status: :error, failure_origin: "budget_exhausted", error_message: "agent exhausted its per-run budget" }
    ]

    genuine_failures.each do |result|
      assert_nil Hive::Babysitter::FailureClassifier.classify(result),
                 "must not suppress genuine failure: #{result.inspect}"
    end
  end
end
