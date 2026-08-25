require "test_helper"
require "hive/conditions/value"

class ConditionsValueTest < Minitest::Test
  def test_observation_rejects_each_required_semantic_field
    variants = [
      valid_record.merge("reason" => ""),
      valid_record.merge("occurred_at" => "not-a-time"),
      valid_record.merge("provenance" => {}),
      valid_record.merge("evidence" => []),
      valid_record.merge("payload" => { "condition" => "Unknown", "state" => "satisfied" }),
      valid_record.merge("payload" => nil),
      valid_record.merge("payload" => [])
    ]

    variants.each do |record|
      assert_raises(Hive::Conditions::InvalidCondition) do
        Hive::Conditions::Value.validate_observation!(record)
      end
    end
  end

  def test_observation_rejects_non_hash_payload_without_crashing
    [nil, [], "AgentHealthy", 42].each do |payload|
      error = assert_raises(Hive::Conditions::InvalidCondition) do
        Hive::Conditions::Value.validate_observation!(valid_record.merge("payload" => payload))
      end
      assert_match(/payload must be a hash/, error.message)
    end
  end

  private

  def valid_record
    {
      "occurred_at" => "2026-07-17T12:00:00Z",
      "reason" => "attempt_live",
      "provenance" => { "source" => "test" },
      "evidence" => [
        { "type" => "attempt_lease", "attempt_id" => "attempt-1",
          "lease_version" => 1, "state" => "running" }
      ],
      "payload" => { "condition" => "AgentHealthy", "state" => "satisfied" }
    }
  end
end
