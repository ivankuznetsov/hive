require "test_helper"
require "hive/daily_digest/pruner"

class DailyDigestPrunerTest < Minitest::Test
  include HiveTestHelper

  def test_dry_run_and_confirm_only_target_closed_records_before_date
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      %w[2026-08-28 2026-08-29].each { |date| store.write_base(record(date, "closed")) }
      store.write_base(record("2026-08-30", "open"))
      pruner = Hive::DailyDigest::Pruner.new(store: store, clock: -> { Time.iso8601("2026-08-30T12:00:00Z") })

      dry = pruner.call(before: "2026-08-30", dry_run: true)
      assert_equal %w[2026-08-28 2026-08-29], dry.fetch("eligible")
      assert_equal "closed", store.read("2026-08-28").fetch("lifecycle")

      done = pruner.call(before: "2026-08-30", confirm: true)
      assert_equal %w[2026-08-28 2026-08-29], done.fetch("pruned")
      assert_equal "pruned", store.read("2026-08-28").fetch("lifecycle")
      assert_equal "open", store.read("2026-08-30").fetch("lifecycle")
    end
  end

  private

  def record(date, lifecycle)
    interval = Hive::DailyDigest::Calendar.new(time_zone: "UTC").interval_for(date, sequence: 1)
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      **interval.slice("local_date", "sequence", "time_zone", "starts_at", "ends_at", "boundary_kind"),
      "lifecycle" => lifecycle,
      "closed_at" => lifecycle == "closed" ? "2026-08-31T00:00:00Z" : nil,
      "completeness" => "complete", "content" => "empty",
      "last_materialized_at" => "2026-08-30T00:00:00Z",
      "projects" => [], "items" => [], "attention" => [], "gaps" => [], "source_frontiers" => {}
    }
  end
end
