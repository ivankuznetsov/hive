require "test_helper"
require "hive/daily_digest/recovery"

class DailyDigestRecoveryTest < Minitest::Test
  def test_retries_only_when_the_selected_source_has_an_unresolved_gap
    before = {
      "lifecycle" => "closed",
      "effective_gaps" => [ { "gap_id" => "gap:github", "source" => "github" } ]
    }
    after = before.merge("effective_gaps" => [], "amendments" => [ { "amendment_id" => "amendment:1" } ])
    reads = [ before, after ]
    reader = Object.new
    reader.define_singleton_method(:read) { |**| reads.shift }
    coordinator = Object.new
    calls = []
    coordinator.define_singleton_method(:refresh) { |**args| calls << args; [] }
    recovery = Hive::DailyDigest::Recovery.new(reader: reader, coordinator: coordinator)

    result = recovery.call(date: "2026-08-30", source: "github")

    assert_equal [ {
      date: "2026-08-30", attempted_gap_ids: [ "gap:github" ]
    } ], calls
    assert_equal [ "gap:github" ], result.fetch("resolved_gap_ids")
  end

  def test_retry_reports_a_gap_that_remains_unresolved
    gap = { "gap_id" => "gap:github", "source" => "github" }
    reads = [ { "lifecycle" => "closed", "effective_gaps" => [ gap ] },
              { "lifecycle" => "closed", "effective_gaps" => [ gap ] } ]
    reader = Object.new
    reader.define_singleton_method(:read) { |**| reads.shift }
    coordinator = Object.new
    coordinator.define_singleton_method(:refresh) { |**| [] }

    result = Hive::DailyDigest::Recovery.new(reader: reader, coordinator: coordinator)
                                        .call(date: "2026-08-30")

    assert_equal [], result.fetch("resolved_gap_ids")
    assert_equal [ "gap:github" ], result.fetch("attempted_gap_ids")
  end

  def test_no_matching_gap_is_a_noop
    reader = Object.new
    reader.define_singleton_method(:read) do |**|
      { "lifecycle" => "closed", "effective_gaps" => [] }
    end
    coordinator = Object.new
    coordinator.define_singleton_method(:refresh) { |**| raise "must not refresh" }

    result = Hive::DailyDigest::Recovery.new(reader: reader, coordinator: coordinator)
                                        .call(date: "2026-08-30", source: "github")

    assert_equal "nothing_to_retry", result.fetch("status")
  end

  def test_rejects_missing_and_open_records
    coordinator = Object.new
    coordinator.define_singleton_method(:refresh) { |**| flunk "must not refresh" }
    [
      { "reader_status" => "missing", "local_date" => "2026-08-30" },
      { "reader_status" => "ok", "lifecycle" => "open" }
    ].each do |value|
      reader = Object.new
      reader.define_singleton_method(:read) { |**| value }
      assert_raises(Hive::DailyDigest::Error) do
        Hive::DailyDigest::Recovery.new(reader: reader, coordinator: coordinator)
                                   .call(date: "2026-08-30")
      end
    end
  end
end
