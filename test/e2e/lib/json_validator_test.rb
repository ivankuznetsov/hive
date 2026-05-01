require_relative "../../test_helper"
require_relative "json_validator"

class E2EJsonValidatorTest < Minitest::Test
  def test_validates_status_payload
    payload = {
      "schema" => "hive-status",
      "schema_version" => 1,
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
end
