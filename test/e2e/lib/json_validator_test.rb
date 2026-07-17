require_relative "../../test_helper"
require_relative "json_validator"

class E2EJsonValidatorTest < Minitest::Test
  def test_validates_status_payload
    payload = {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
      "ok" => true,
      "generated_at" => Time.now.utc.iso8601,
      "projects" => []
    }

    result = Hive::E2E::JsonValidator.new.validate("hive-status", payload)

    assert result.ok?, result.errors.inspect
  end

  def test_reports_no_schema
    result = Hive::E2E::JsonValidator.new.validate("missing", "{}")

    assert_equal :no_schema, result.status
  end

  def test_reports_parse_errors
    result = Hive::E2E::JsonValidator.new.validate("hive-status", "{")

    assert_equal :invalid, result.status
    assert result.parse_error
  end

  def test_scenario_inventory_requires_incident_lifecycle_fields_on_every_row
    row = {
      "name" => "ordinary", "tags" => [], "description" => "", "path" => "ordinary.yml",
      "steps_count" => 1, "incident_id" => nil, "sibling_task_id" => nil, "pending" => false
    }
    payload = { "schema" => "hive-e2e-scenarios", "schema_version" => 1, "scenarios" => [ row ] }

    assert Hive::E2E::JsonValidator.new.validate("hive-e2e-scenarios", payload).ok?
    refute Hive::E2E::JsonValidator.new.validate(
      "hive-e2e-scenarios", payload.merge("scenarios" => [ row.reject { |key, _| key == "pending" } ])
    ).ok?
  end
end
