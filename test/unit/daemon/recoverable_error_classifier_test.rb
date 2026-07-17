require "test_helper"
require "hive/daemon/recoverable_error_classifier"

class HiveDaemonRecoverableErrorClassifierTest < Minitest::Test
  def classify(reason, attrs = {})
    Hive::Daemon::RecoverableErrorClassifier.classify(reason: reason, attrs: attrs)
  end

  def test_classifier_returns_canonical_diagnostics_not_eligibility
    assert_equal "codex_auth", classify(
      "implementer_failed", "provider" => "codex", "message" => "401 missing bearer auth"
    )
    assert_equal "implementer_failed", classify(
      "implementer_failed", "provider" => "codex", "message" => "compile error"
    )
    assert_equal "unknown", classify("future_external_reason", "message" => "safe")
  end
end
