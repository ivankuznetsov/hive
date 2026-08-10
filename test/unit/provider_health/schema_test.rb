require_relative "../../test_helper"
require "json_schemer"
require "pathname"
require "hive/provider_health/circuit"
require "hive/provider_health/event"

class ProviderHealthSchemaTest < Minitest::Test
  def test_projection_and_event_validate_and_reject_raw_fields
    projection = Hive::ProviderHealth::Circuit.closed(scope: scope).to_h
    event = Hive::ProviderHealth::Event.new(
      event_id: "event-1",
      sequence: 1,
      scope: scope,
      journal_epoch: 0,
      kind: "evidence_rejected",
      occurred_at: Time.utc(2026, 8, 10),
      idempotency_key: "a" * 64,
      expected_generation: 0,
      previous_generation: 0,
      resulting_generation: 0,
      payload: { "reason" => "late_receipt" }
    ).to_h

    assert_empty projection_schema.validate(projection).to_a
    assert_empty event_schema.validate(event).to_a

    %w[message stdout stderr prompt tokens credentials tool_output].each do |raw_field|
      refute_empty projection_schema.validate(projection.merge(raw_field => "secret-canary")).to_a
      refute_empty event_schema.validate(event.merge(raw_field => "secret-canary")).to_a
    end
  end

  def test_event_payload_is_closed_by_kind
    event = Hive::ProviderHealth::Event.new(
      event_id: "event-1",
      sequence: 1,
      scope: scope,
      journal_epoch: 0,
      kind: "evidence_rejected",
      occurred_at: Time.utc(2026, 8, 10),
      idempotency_key: "a" * 64,
      expected_generation: 0,
      previous_generation: 0,
      resulting_generation: 0,
      payload: { "reason" => "late_receipt" }
    ).to_h

    event = Hive::ProviderHealth.deep_copy(event)
    event["payload"] = event.fetch("payload").merge("message" => "secret-canary")
    refute_empty event_schema.validate(event).to_a
  end

  private

  def scope
    @scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "codex-primary")
  end

  def projection_schema
    @projection_schema ||= JSONSchemer.schema(
      Pathname(Hive::Schemas.schema_path("hive-provider-health"))
    )
  end

  def event_schema
    @event_schema ||= JSONSchemer.schema(
      Pathname(Hive::Schemas.schema_path("hive-provider-health-event"))
    )
  end
end
