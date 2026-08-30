require "test_helper"
require "hive/daily_digest/record"

class DailyDigestRecordTest < Minitest::Test
  def test_rejects_every_invalid_base_axis
    invalid = [
      [ [], /must be an object/ ],
      [ base.merge("schema_version" => 2), /unsupported/ ],
      [ base.merge("closed_at" => "2026-08-31T00:00:00Z"), /open digest/ ],
      [ base.merge("completeness" => "partial"), /empty content/ ],
      [ base.merge("source_frontiers" => []), /source_frontiers/ ],
      [ base.merge("sequence" => 0), /sequence/ ],
      [ base.merge("local_date" => "bad"), /local_date/ ],
      [ base.merge("last_materialized_at" => "bad"), /ISO-8601/ ],
      [ base.merge("lifecycle" => "missing"), /must be one of/ ],
      [ base.merge("interval_id" => "bad"), /interval_id/ ],
      [ base.merge("duration_seconds" => 1), /persisted interval/ ],
      [ base.merge("cutover" => {}), /calendar-day/ ],
      [ base.merge("boundary_kind" => "zone_cutover"), /require cutover/ ]
    ]

    invalid.each do |value, message|
      error = assert_raises(Hive::DailyDigest::InvalidRecord) do
        Hive::DailyDigest::Record.prepare(value)
      end
      assert_match message, error.message
    end
  end

  def test_rejects_invalid_amendment_frontiers_and_non_json_values
    amendment = {
      "amendment_id" => "amendment-1", "kind" => "late_observation",
      "source" => "test", "event_at" => nil,
      "observed_at" => "2026-08-31T00:00:00Z",
      "amended_at" => "2026-08-31T00:00:01Z",
      "items" => [], "resolved_gap_ids" => [], "source_frontiers" => []
    }
    error = assert_raises(Hive::DailyDigest::InvalidRecord) do
      Hive::DailyDigest::Record.prepare_amendment("2026-08-30", amendment)
    end
    assert_match(/source_frontiers/, error.message)

    error = assert_raises(Hive::DailyDigest::InvalidRecord) do
      Hive::DailyDigest::Record.prepare("bad" => Float::NAN)
    end
    assert_match(/not JSON-safe/, error.message)
  end

  def test_valid_amendment_is_canonicalized_and_frozen
    amendment = Hive::DailyDigest::Record.prepare_amendment("2026-08-30", {
      amendment_id: "amendment-1", kind: "late_observation", source: "test",
      event_at: nil, observed_at: "2026-08-31T00:00:00Z",
      amended_at: "2026-08-31T00:00:01Z", items: [], resolved_gap_ids: []
    })

    assert_equal "2026-08-30", amendment.fetch("local_date")
    assert_equal({}, amendment.fetch("source_frontiers"))
    assert_predicate amendment, :frozen?
  end

  private

  def base
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => "a" * 64,
      "local_date" => "2026-08-30", "sequence" => 1, "time_zone" => "UTC",
      "starts_at" => "2026-08-30T00:00:00Z", "ends_at" => "2026-08-31T00:00:00Z",
      "duration_seconds" => 86_400, "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => "open", "closed_at" => nil,
      "completeness" => "complete", "content" => "empty",
      "last_materialized_at" => "2026-08-30T12:00:00Z",
      "projects" => [], "items" => [], "attention" => [], "gaps" => [],
      "source_frontiers" => {}
    }
  end
end
