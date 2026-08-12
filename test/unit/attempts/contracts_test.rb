require_relative "../../test_helper"
require "hive/attempts/contracts"

class AttemptsContractsTest < Minitest::Test
  def test_dispatch_result_carries_optional_structured_routing_decision
    decision = Object.new.freeze
    result = Hive::Attempts::DispatchResult.new(
      status: :no_route,
      attempt: nil,
      receipt: nil,
      attach_descriptor: nil,
      reason: "no_eligible_provider_route",
      decision: decision
    )

    assert_equal :no_route, result.status
    assert_same decision, result.decision
    refute result.accepted?
    refute result.live?
  end

  def test_existing_callers_default_decision_to_nil
    result = Hive::Attempts::DispatchResult.new(
      status: :accepted,
      attempt: Object.new,
      receipt: nil,
      attach_descriptor: nil,
      reason: nil
    )

    assert_nil result.decision
    assert result.accepted?
    assert result.live?
  end
end
