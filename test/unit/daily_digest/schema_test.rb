require "test_helper"
require "json_schemer"
require "hive/daily_digest/record"

class DailyDigestSchemaTest < Minitest::Test
  def test_record_schema_accepts_the_store_contract_and_is_closed
    record = Hive::DailyDigest::Record.prepare(
      "schema" => "hive-digest-record", "schema_version" => 1,
      "local_date" => "2026-08-30", "sequence" => 1, "time_zone" => "Europe/London",
      "starts_at" => "2026-08-29T23:00:00.000000Z",
      "ends_at" => "2026-08-30T23:00:00.000000Z", "boundary_kind" => "calendar_day",
      "lifecycle" => "closed", "closed_at" => "2026-08-31T00:00:00.000000Z",
      "completeness" => "complete", "content" => "empty",
      "last_materialized_at" => "2026-08-31T00:00:00.000000Z",
      "projects" => [], "items" => [], "attention" => [], "gaps" => [],
      "source_frontiers" => {}
    )
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest-record"))))

    assert_empty schema.validate(record).to_a
    refute schema.valid?(record.merge("question" => "secret"))
  end
end
