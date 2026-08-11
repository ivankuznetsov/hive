require_relative "../../test_helper"
require "hive/provider_health/audit"

class ProviderHealthAuditTest < Minitest::Test
  def test_receipt_records_trusted_actor_reason_target_states_and_generation
    receipt = Hive::ProviderHealth::Audit::Receipt.new(
      actor: "uid:1000",
      reason: "planned provider maintenance",
      target: scope,
      action: "block",
      occurred_at: Time.utc(2026, 8, 10),
      previous_state: state(generation: 0, manual_blocked: false),
      new_state: state(generation: 1, manual_blocked: true),
      generation: 1,
      event_id: "event-1"
    )

    assert_equal "uid:1000", receipt.actor
    assert_equal 1, receipt.generation
    assert_equal scope.to_h, receipt.to_h.fetch("target")
    assert receipt.to_h.frozen?
  end

  def test_reason_rejects_blank_multiline_controls_credential_like_and_oversized_input
    invalid = [
      "",
      "   ",
      "first\nsecond",
      "control\u0000byte",
      "api_key=secret-canary",
      "Bearer secret-canary",
      "sk-ant-abcdefghijklmnopqrstuvwx",
      "x" * (Hive::ProviderHealth::MAX_REASON_BYTES + 1)
    ]

    invalid.each do |reason|
      error = assert_raises(Hive::ProviderHealth::InvalidMutation) do
        Hive::ProviderHealth::Audit.validate_reason(reason)
      end
      refute_includes error.message, "secret-canary"
    end
  end

  def test_actor_is_bounded_and_control_free
    assert_equal "operator", Hive::ProviderHealth::Audit.validate_actor("operator")
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::Audit.validate_actor("operator\nspoof")
    end
  end

  def test_receipt_parser_action_state_and_reference_fail_closed
    valid = receipt.to_h
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::Audit::Receipt.from_h(valid.merge("extra" => true))
    end

    incomplete = valid.dup
    incomplete.define_singleton_method(:fetch) do |key, *defaults|
      raise KeyError, key if key == "actor"

      super(key, *defaults)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::Audit::Receipt.from_h(incomplete)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      receipt(action: "probe")
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::Audit.validate_state("automatic_state" => "closed")
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::Audit.validate_state(
        state(generation: 0, manual_blocked: false).merge("automatic_state" => "unknown")
      )
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::Audit.validate_reference(
        "path" => "safe.json", "size" => 1, "sha256" => "a" * 64,
        "message" => "unsafe"
      )
    end
  end

  private

  def scope
    @scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "codex-primary")
  end

  def receipt(action: "block")
    Hive::ProviderHealth::Audit::Receipt.new(
      actor: "uid:1000", reason: "planned provider maintenance", target: scope,
      action: action, occurred_at: Time.utc(2026, 8, 10),
      previous_state: state(generation: 0, manual_blocked: false),
      new_state: state(generation: 1, manual_blocked: true),
      generation: 1, event_id: "event-1"
    )
  end


  def state(generation:, manual_blocked:)
    {
      "automatic_state" => "closed",
      "manual_blocked" => manual_blocked,
      "probe_owned" => false,
      "generation" => generation,
      "journal_epoch" => 0
    }
  end
end
