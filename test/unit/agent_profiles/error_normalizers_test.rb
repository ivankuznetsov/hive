require "test_helper"
require "hive/agent_profiles/error_normalizers"

class AgentProfilesErrorNormalizersTest < Minitest::Test
  ROUTE = {
    "route_id" => "account-a/model-a",
    "provider_account_id" => "account-a",
    "adapter" => "codex",
    "launch_binding_id" => "default",
    "model" => "model-a",
    "effort" => "high"
  }.freeze
  CLAUDE_ROUTE = ROUTE.merge("adapter" => "claude").freeze

  def test_every_closed_failure_class_requires_and_preserves_exact_scope
    Hive::AgentProfiles::ErrorNormalizers::PROVIDER_CLASSES.each do |failure_class|
      signal = normalize_diagnostic(error(failure_class, "provider_account"))
      assert_equal failure_class, signal.fetch("failure_class")
      assert_equal "provider_account", signal.dig("scope", "kind")
      assert_nil signal.dig("scope", "model")
    end

    Hive::AgentProfiles::ErrorNormalizers::MODEL_CLASSES.each do |failure_class|
      signal = normalize_diagnostic(error(failure_class, "model", model: "model-a"))
      assert_equal failure_class, signal.fetch("failure_class")
      assert_equal "model-a", signal.dig("scope", "model")
    end
  end

  def test_real_claude_subscription_rate_limit_is_the_only_trusted_transport_shape
    capture = capture_for("claude")
    signal = Hive::AgentProfiles::ErrorNormalizers.normalize(
      adapter: "claude", event: capture.fetch("observed_event"), route: CLAUDE_ROUTE
    )

    assert_equal "account_quota", signal.fetch("failure_class")
    assert_equal "provider_account", signal.dig("scope", "kind")
    assert_equal "account-a", signal.dig("scope", "provider_account_id")
    assert_equal "claude_stream_json_transport", signal.fetch("provenance")

    %w[codex grok].each do |adapter|
      capture = capture_for(adapter)
      assert_nil Hive::AgentProfiles::ErrorNormalizers.normalize(
        adapter: adapter,
        event: capture.fetch("observed_event"),
        route: ROUTE.merge("adapter" => adapter)
      )
    end
  end

  def test_final_messages_stdout_tool_output_and_ambiguous_errors_are_task_local
    adversarial = [
      { "type" => "assistant", "message" => "provider_outage account-a" },
      { "type" => "tool", "output" => codex_event(error("authentication", "provider_account")) },
      { "type" => "turn.failed", "error" => { "message" => "429 quota exceeded" } },
      codex_event(error("account_quota", "provider_account")),
      codex_event(error("model_capacity", "model", model: nil)),
      codex_event(error("model_capacity", "model", model: "other-model")),
      codex_event(error("provider_outage", "provider_account").merge("provider_account_id" => "other"))
    ]

    adversarial.each do |event|
      assert_nil Hive::AgentProfiles::ErrorNormalizers.normalize(
        adapter: "codex", event: event, route: ROUTE
      )
    end
  end

  def test_raw_message_content_cannot_change_the_safe_signal
    first = claude_event.merge("message" => "secret-one")
    second = claude_event.merge("message" => "secret-two")

    assert_equal normalize(first), normalize(second)
    refute_includes JSON.generate(normalize(first)), "secret"
  end

  def test_provider_diagnostic_channel_is_explicit_and_conservative
    diagnostic = error("provider_outage", "provider_account").merge(
      "type" => "provider_diagnostic"
    )
    signal = Hive::AgentProfiles::ErrorNormalizers.normalize_diagnostic(
      diagnostic: diagnostic, route: ROUTE
    )
    assert_equal "provider_diagnostic", signal.fetch("provenance")
    assert_nil Hive::AgentProfiles::ErrorNormalizers.normalize_diagnostic(
      diagnostic: { "type" => "assistant" }, route: ROUTE
    )

    explosive = Object.new
    explosive.define_singleton_method(:to_s) { raise ArgumentError, "invalid identifier" }
    assert_nil Hive::AgentProfiles::ErrorNormalizers.normalize_diagnostic(
      diagnostic: diagnostic, route: ROUTE.merge("provider_account_id" => explosive)
    )
  end

  def test_transport_normalization_swallows_invalid_scalar_coercion
    explosive = Object.new
    explosive.define_singleton_method(:to_s) { raise TypeError, "invalid identifier" }

    assert_nil Hive::AgentProfiles::ErrorNormalizers.normalize(
      adapter: "claude", event: claude_event,
      route: CLAUDE_ROUTE.merge("provider_account_id" => explosive)
    )
  end

  private

  def normalize(event)
    Hive::AgentProfiles::ErrorNormalizers.normalize(
      adapter: "claude", event: event, route: CLAUDE_ROUTE
    )
  end

  def normalize_diagnostic(payload)
    Hive::AgentProfiles::ErrorNormalizers.normalize_diagnostic(
      diagnostic: payload.merge("type" => "provider_diagnostic"), route: ROUTE
    )
  end

  def capture_for(adapter)
    JSON.parse(
      File.read(File.expand_path("../../fixtures/provider_errors/#{adapter}.json", __dir__))
    )
  end

  def claude_event
    {
      "type" => "rate_limit_event",
      "rate_limit_info" => {
        "status" => "rejected",
        "rateLimitType" => "five_hour"
      }
    }
  end

  def codex_event(payload)
    {
      "type" => "turn.failed",
      "error" => payload.merge("type" => "provider_error", "origin" => "provider_transport")
    }
  end

  def error(failure_class, scope, model: :absent)
    value = {
      "class" => failure_class,
      "scope" => scope,
      "provider_account_id" => "account-a",
      "reset_hint_seconds" => 30
    }
    value["model"] = model unless model == :absent
    value
  end
end
