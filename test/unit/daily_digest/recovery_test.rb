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

    assert_equal [ { date: "2026-08-30" } ], calls
    assert_equal [ "gap:github" ], result.fetch("resolved_gap_ids")
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
end
