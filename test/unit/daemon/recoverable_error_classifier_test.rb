require "test_helper"
require "hive/daemon/recoverable_error_classifier"

class HiveDaemonRecoverableErrorClassifierTest < Minitest::Test
  def classify(reason, attrs = {})
    Hive::Daemon::RecoverableErrorClassifier.classify(
      reason: reason,
      attrs: attrs,
      stage: "4-execute",
      workflow: "coding"
    )
  end

  def test_codex_implementer_401_missing_bearer_is_recoverable
    attrs = {
      "provider" => "codex",
      "message" => "Codex failed: 401 Missing bearer/basic auth"
    }

    assert_equal :codex_auth, classify("implementer_failed", attrs)
  end

  def test_legacy_codex_401_marker_without_provider_is_recoverable
    attrs = {
      "message" => "request failed with 401 missing bearer token"
    }

    assert_equal :codex_auth, classify("implementer_failed", attrs)
  end

  def test_business_logic_implementer_failure_is_not_recoverable
    attrs = {
      "provider" => "codex",
      "message" => "exit_code=1 compile error"
    }

    assert_nil classify("implementer_failed", attrs)
  end

  def test_claude_provider_with_401_text_is_not_codex_auth
    attrs = {
      "provider" => "claude",
      "message" => "401 Missing bearer/basic auth"
    }

    assert_nil classify("implementer_failed", attrs)
  end

  def test_401_without_auth_signature_is_not_recoverable
    attrs = {
      "provider" => "codex",
      "message" => "HTTP 401 from application test fixture"
    }

    assert_nil classify("implementer_failed", attrs)
  end

  def test_claude_launch_failed_is_recoverable_category
    assert_equal :claude_launcher, classify("claude_launch_failed", {})
  end

  def test_other_reasons_are_not_recoverable
    %w[exit_code dirty_worktree review_failed merge_conflict limits_reached].each do |reason|
      assert_nil classify(reason, "message" => "401 Missing bearer/basic auth")
    end
  end
end
