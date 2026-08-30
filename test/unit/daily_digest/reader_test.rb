require "test_helper"
require "hive/daily_digest/reader"

class DailyDigestReaderTest < Minitest::Test
  include HiveTestHelper

  def test_read_is_pure_filters_projects_and_keeps_global_gaps
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record)
      before = File.binread(store.base_path("2026-08-30"))
      reader = Hive::DailyDigest::Reader.new(
        store: store, config_loader: -> { config },
        clock: -> { Time.iso8601("2026-08-30T10:00:30Z") }
      )

      result = reader.read(project: "one")

      assert_equal "ok", result.fetch("reader_status")
      assert_equal [ "one" ], result.fetch("items").map { |item| item.fetch("project") }
      assert_equal [ "global", "one" ], result.fetch("effective_gaps").map { |gap| gap.fetch("scope") }.sort
      assert_equal before, File.binread(store.base_path("2026-08-30"))
    end
  end

  def test_missing_pruned_and_stale_are_distinct
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      reader = Hive::DailyDigest::Reader.new(
        store: store, config_loader: -> { config },
        clock: -> { Time.iso8601("2026-08-30T12:00:00Z") }
      )
      assert_equal "missing", reader.read(date: "2026-08-30").fetch("reader_status")

      store.write_base(record)
      assert_equal true, reader.read.fetch("stale")
      store.write_base(record.merge("lifecycle" => "closed", "closed_at" => "2026-08-31T00:00:00Z"))
      store.prune("2026-08-30", pruned_at: "2026-09-01T00:00:00Z", reason: "test")
      assert_equal "pruned", reader.read(date: "2026-08-30").fetch("reader_status")
    end
  end

  private

  def config
    {
      "coverage_started_at" => "2026-08-30T00:00:00Z",
      "freshness_budget_sec" => 60
    }
  end

  def record
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "local_date" => "2026-08-30", "sequence" => 1, "time_zone" => "UTC",
      "starts_at" => "2026-08-30T00:00:00.000000Z", "ends_at" => "2026-08-31T00:00:00.000000Z",
      "boundary_kind" => "calendar_day", "lifecycle" => "open", "closed_at" => nil,
      "completeness" => "partial", "content" => "non_empty",
      "last_materialized_at" => "2026-08-30T10:00:00.000000Z",
      "projects" => [ { "project_id" => "one", "name" => "one" }, { "project_id" => "two", "name" => "two" } ],
      "items" => [ item("one"), item("two") ], "attention" => [],
      "gaps" => [ gap("global", nil), gap("one", "one"), gap("two", "two") ],
      "source_frontiers" => {}
    }
  end

  def item(project)
    { "fact_id" => "fact:#{project}", "kind" => "changed", "project_id" => project,
      "project" => project, "occurred_at" => "2026-08-30T09:00:00Z",
      "observed_at" => "2026-08-30T09:00:00Z" }
  end

  def gap(scope, project_id)
    { "gap_id" => "gap:#{scope}", "source" => "test", "scope" => scope,
      "reason" => "unavailable", "reason_code" => "unavailable",
      "observed_at" => "2026-08-30T09:00:00Z", "freshness_at" => nil,
      "project_id" => project_id, "task_slug" => nil }
  end
end
