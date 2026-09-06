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
      assert_equal "2026-08-30", reader.read(date: "2026-08-29").fetch("next_date")
      assert_equal "2026-08-30", reader.read(date: "2026-08-31").fetch("previous_date")
      assert_equal true, reader.read.fetch("stale")
      store.write_base(record.merge("lifecycle" => "closed", "closed_at" => "2026-08-31T00:00:00Z"))
      store.prune("2026-08-30", pruned_at: "2026-09-01T00:00:00Z", reason: "test")
      pruned = reader.read(date: "2026-08-30")
      assert_equal "pruned", pruned.fetch("reader_status")
      assert_nil pruned.fetch("previous_date")
      assert_nil pruned.fetch("next_date")
    end
  end

  def test_navigation_filtering_and_invalid_freshness_cover_defensive_views
    value = record.merge(
      "lifecycle" => "closed", "closed_at" => "2026-08-31T00:00:00Z",
      "amendments" => [ {
        "amendment_id" => "late", "items" => [ item("one"), item("two") ],
        "attention" => [ { "attention_id" => "a1", "project_id" => "one" } ],
        "gaps" => [ gap("global-late", nil), gap("two-late", "two") ],
        "resolved_gap_ids" => [ "one-resolved", "two-resolved" ],
        "resolved_gaps" => [
          gap("one-resolved", "one"), gap("two-resolved", "two")
        ]
      } ]
    )
    store = Object.new
    store.define_singleton_method(:read) { |_date| value }
    store.define_singleton_method(:intervals) do
      [ value.slice("local_date", "starts_at", "ends_at") ]
    end
    reader = Hive::DailyDigest::Reader.new(store: store, config_loader: -> { config })
    filtered = reader.read(date: "2026-08-30", project: "one")
    amendment = filtered.fetch("amendments").first
    assert_equal [ "one" ], amendment.fetch("items").map { |row| row.fetch("project_id") }
    assert_equal [ "one" ], amendment.fetch("attention").map { |row| row.fetch("project_id") }
    assert_equal [ "global-late" ], amendment.fetch("gaps").map { |row| row.fetch("scope") }
    assert_equal [ "gap:one-resolved" ], amendment.fetch("resolved_gap_ids")
    assert_equal [ "one-resolved" ],
                 amendment.fetch("resolved_gaps").map { |row| row.fetch("scope") }
    assert_nil reader.previous_date("2026-08-30")
    assert_nil reader.next_date("2026-08-30")

    assert_equal({ "previous_date" => nil, "next_date" => nil },
                 reader.send(:missing_navigation, "bad"))
    assert_raises(Hive::DailyDigest::InvalidRecord) { reader.read(date: "bad") }

    malformed_coverage = Hive::DailyDigest::Reader.new(
      store: store, config_loader: -> { config.merge("coverage_started_at" => "bad") }
    ).send(:missing, "2026-08-29", config.merge("coverage_started_at" => "bad"))
    assert_equal false, malformed_coverage.fetch("precoverage")

    with_tmp_dir do |dir|
      real_store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      real_store.write_base(record)
      stale = Hive::DailyDigest::Reader.new(
        store: real_store,
        config_loader: -> { config.merge("freshness_budget_sec" => "bad") },
        clock: -> { Time.iso8601("2026-08-30T10:00:30Z") }
      ).read(date: "2026-08-30")
      assert_equal true, stale.fetch("stale")
    end
  end

  def test_project_filter_drops_an_amendment_with_only_other_project_content
    other_only = {
      "amendment_id" => "other", "items" => [ item("two") ],
      "attention" => [], "gaps" => [], "resolved_gap_ids" => [ "two" ],
      "resolved_gaps" => [ gap("two", "two") ]
    }
    value = record.merge("amendments" => [ other_only ])
    store = Object.new
    store.define_singleton_method(:read) { |_date| value }
    store.define_singleton_method(:intervals) { [] }

    filtered = Hive::DailyDigest::Reader.new(
      store: store, config_loader: -> { config }
    ).read(date: "2026-08-30", project: "one")

    assert_empty filtered.fetch("amendments")
  end

  def test_project_filter_recomputes_complete_empty_view_axes
    value = record.merge(
      "items" => [ item("two") ], "attention" => [],
      "gaps" => [ gap("two", "two") ], "effective_gaps" => [ gap("two", "two") ]
    )
    store = Object.new
    store.define_singleton_method(:read) { |_date| value }
    store.define_singleton_method(:intervals) { [] }

    filtered = Hive::DailyDigest::Reader.new(
      store: store, config_loader: -> { config },
      clock: -> { Time.iso8601("2026-08-30T10:00:30Z") }
    ).read(date: "2026-08-30", project: "one")

    assert_equal "complete", filtered.fetch("effective_completeness")
    assert_equal "empty", filtered.fetch("effective_content")
    assert_empty filtered.fetch("items")
    assert_empty filtered.fetch("effective_gaps")
  end

  def test_stale_empty_open_record_has_unknown_view_content
    value = record.merge(
      "items" => [], "attention" => [], "gaps" => [], "effective_gaps" => [],
      "content" => "empty", "effective_content" => "empty"
    )
    store = Object.new
    store.define_singleton_method(:read) { |_date| value }
    store.define_singleton_method(:intervals) { [] }

    stale = Hive::DailyDigest::Reader.new(
      store: store, config_loader: -> { config },
      clock: -> { Time.iso8601("2026-08-30T12:00:00Z") }
    ).read(date: "2026-08-30")

    assert_equal true, stale.fetch("stale")
    assert_equal "partial", stale.fetch("view_completeness")
    assert_equal "unknown", stale.fetch("view_content")
  end

  def test_missing_current_interval_keeps_nearest_persisted_navigation
    store = Object.new
    store.define_singleton_method(:intervals) do
      [
        { "local_date" => "2026-08-29", "starts_at" => "2026-08-29T00:00:00Z",
          "ends_at" => "2026-08-30T00:00:00Z" },
        { "local_date" => "2026-09-01", "starts_at" => "2026-09-01T00:00:00Z",
          "ends_at" => "2026-09-02T00:00:00Z" }
      ]
    end
    reader = Hive::DailyDigest::Reader.new(
      store: store, config_loader: -> { config },
      clock: -> { Time.iso8601("2026-08-30T12:00:00Z") }
    )

    result = reader.read

    assert_equal "missing", result.fetch("reader_status")
    assert_equal "2026-08-29", result.fetch("previous_date")
    assert_equal "2026-09-01", result.fetch("next_date")
  end


  def test_default_dependencies_can_be_constructed_without_reading
    assert_instance_of Hive::DailyDigest::Reader, Hive::DailyDigest::Reader.new

    store = Object.new
    store.define_singleton_method(:intervals) { [] }
    reader = Hive::DailyDigest::Reader.new(store: store, config_loader: -> { {} })
    assert_equal "missing", reader.read.fetch("reader_status")
  end

  def test_unknown_project_has_a_stable_usage_exit
    assert_equal Hive::ExitCodes::USAGE,
                 Hive::DailyDigest::Reader::UnknownProject.new.exit_code
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
      "interval_id" => "a" * 64,
      "local_date" => "2026-08-30", "sequence" => 1, "time_zone" => "UTC",
      "starts_at" => "2026-08-30T00:00:00.000000Z", "ends_at" => "2026-08-31T00:00:00.000000Z",
      "duration_seconds" => 86_400, "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => "open", "closed_at" => nil,
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
