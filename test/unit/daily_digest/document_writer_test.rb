require "test_helper"
require "hive/daily_digest/document_writer"
require "hive/daily_digest/reader"

class DailyDigestDocumentWriterTest < Minitest::Test
  include HiveTestHelper

  def test_document_uses_pr_evidence_before_local_tracking_started_and_reuses_saved_text
    with_tmp_global_config do |home|
      config = { "enabled" => true, "time_zone" => "UTC", "coverage_started_at" => "2026-09-16T12:00:00Z" }
      store = Hive::DailyDigest::Store.new(root: File.join(home, "documents"))
      calls = []
      generator = Object.new
      generator.define_singleton_method(:generate) { |facts| calls << facts; "Hive\n\nLoading now uses the saved snapshot immediately. PR #1." }
      loader = ->(**_) { facts }
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { config }, projects_loader: -> { [] }, store: store,
        facts_loader: loader, generator: generator, clock: -> { Time.utc(2026, 9, 16, 13) }
      )
      writer.refresh(date: "2026-09-15")
      record = store.read("2026-09-15")
      assert_includes record.fetch("document"), "saved snapshot"
      assert_equal "closed", record.fetch("lifecycle")
      assert_equal [ { "name" => "ivankuznetsov/hive", "pull_requests" => 1, "additions" => 120, "deletions" => 30, "commits" => 3 } ], record.fetch("repository_stats")
      reader = Hive::DailyDigest::Reader.new(store: store, config_loader: -> { config }, clock: -> { Time.utc(2026, 9, 16, 13) })
      view = reader.read(project: "ignored-filter")
      assert_equal record.fetch("document"), view.fetch("document")
      assert_nil view["selected_project"]
      assert_equal "2026-09-15", view.fetch("local_date")
      assert_equal 1, calls.length
      assert_equal "Use the saved snapshot", calls.first.dig("digest", "repositories", 0, "pull_requests", 0, "description")
      writer.refresh(date: "2026-09-15")
      assert_equal 1, calls.length
      assert_equal record.fetch("record_id"), store.read("2026-09-15").fetch("record_id")
    end
  end

  def test_closed_document_gets_stats_once_without_rewriting_its_text
    with_tmp_global_config do |home|
      store = Hive::DailyDigest::Store.new(root: File.join(home, "documents"))
      evidence = facts
      generator = Object.new
      generator.define_singleton_method(:generate) { |_| "Original text" }
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { { "enabled" => true, "time_zone" => "UTC" } },
        projects_loader: -> { [] }, store: store, facts_loader: ->(**_) { evidence },
        generator: generator, clock: -> { Time.utc(2026, 9, 15, 13) }
      )
      writer.refresh(date: "2026-09-15")
      legacy = store.read("2026-09-15").reject { |key, _| key == "repository_stats" }
      store.write_base(legacy.merge("lifecycle" => "closed", "closed_at" => "2026-09-16T00:00:00Z"))
      bytes = File.binread(store.base_path("2026-09-15"))
      generator.define_singleton_method(:generate) { |_| raise "must not regenerate" }
      evidence = { "digest" => { "repositories" => [] } }
      assert_raises(Hive::UnavailableError) { writer.refresh(date: "2026-09-15") }
      assert_equal bytes, File.binread(store.base_path("2026-09-15"))
      assert_empty store.read("2026-09-15").fetch("amendments")
      evidence = facts
      assert_equal "enriched", writer.refresh(date: "2026-09-15").first.fetch("status")
      reader = Hive::DailyDigest::Reader.new(store: store,
        config_loader: -> { { "time_zone" => "UTC" } })
      assert_equal 3, reader.read(date: "2026-09-15").fetch("repository_stats").first.fetch("commits")
      assert_equal bytes, File.binread(store.base_path("2026-09-15"))
      assert_equal "unchanged", writer.refresh(date: "2026-09-15").first.fetch("status")
      assert_equal 1, store.read("2026-09-15").fetch("amendments").size
    end
  end

  def test_missing_counts_are_unavailable_and_empty_repositories_have_no_totals
    with_tmp_global_config do |home|
      store = Hive::DailyDigest::Store.new(root: File.join(home, "documents"))
      evidence = facts
      evidence["digest"]["repositories"].first["pull_requests"].first.delete("commits")
      evidence["digest"]["repositories"] << { "name" => "owner/empty", "pull_requests" => [] }
      generator = Object.new
      generator.define_singleton_method(:generate) { |_| "Saved document" }
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { { "enabled" => true, "time_zone" => "UTC" } },
        projects_loader: -> { [] }, store: store, facts_loader: ->(**_) { evidence },
        generator: generator, clock: -> { Time.utc(2026, 9, 16, 13) }
      )
      writer.refresh(date: "2026-09-15")
      stats = store.read("2026-09-15").fetch("repository_stats")
      assert_equal 1, stats.size
      assert_nil stats.first.fetch("commits")
      assert_equal 120, stats.first.fetch("additions")
    end
  end

  def test_failed_generation_preserves_previous_document
    with_tmp_global_config do |home|
      store = Hive::DailyDigest::Store.new(root: File.join(home, "documents"))
      fail_generation = false
      generator = Object.new
      generator.define_singleton_method(:generate) { |_| raise "provider down" if fail_generation; "Saved document" }
      evidence = facts
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { { "enabled" => true, "time_zone" => "UTC" } },
        projects_loader: -> { [] }, store: store, facts_loader: ->(**_) { evidence },
        generator: generator, clock: -> { Time.utc(2026, 9, 15, 13) }
      )
      writer.refresh(date: "2026-09-15")
      before = File.binread(store.base_path("2026-09-15"))
      evidence["digest"]["repositories"][0]["pull_requests"][0]["description"] = "Updated evidence"
      fail_generation = true
      assert_raises(RuntimeError) { writer.refresh(date: "2026-09-15") }
      assert_equal before, File.binread(store.base_path("2026-09-15"))
    end
  end

  def test_empty_day_needs_no_agent_and_pruned_day_stays_pruned
    with_tmp_global_config do |home|
      store = Hive::DailyDigest::Store.new(root: File.join(home, "documents"))
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { { "enabled" => true, "time_zone" => "UTC" } },
        projects_loader: -> { [] }, store: store,
        facts_loader: ->(**_) { { "digest" => { "repositories" => [] } } },
        generator: Object.new, clock: -> { Time.utc(2026, 9, 16, 13) }
      )
      writer.refresh(date: "2026-09-15")
      assert_equal "empty", store.read("2026-09-15").fetch("content")
      assert_match(/No pull requests/, store.read("2026-09-15").fetch("document"))
      store.prune("2026-09-15", pruned_at: "2026-09-16T13:00:00Z", reason: "test")
      assert_raises(Hive::DailyDigest::PrunedRecord) { writer.refresh(date: "2026-09-15") }
    end
  end

  def test_midnight_collection_stays_open_and_existing_zone_is_preserved
    with_tmp_global_config do |home|
      store = Hive::DailyDigest::Store.new(root: File.join(home, "documents"))
      now = Time.utc(2026, 9, 15, 23, 59, 59)
      config = { "enabled" => true, "time_zone" => "UTC" }
      generator = Object.new
      generator.define_singleton_method(:generate) { |_| "Saved document" }
      loader = lambda do |**options|
        assert_equal "UTC", options.fetch(:time_zone)
        now = Time.utc(2026, 9, 16, 0, 0, 1)
        facts
      end
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { config }, projects_loader: -> { [] }, store: store,
        facts_loader: loader, generator: generator, clock: -> { now }
      )
      writer.refresh(date: "2026-09-15")
      original = store.read("2026-09-15")
      assert_equal "open", original.fetch("lifecycle")
      config["time_zone"] = "Europe/London"
      writer.refresh(date: "2026-09-15")
      closed = store.read("2026-09-15")
      assert_equal "closed", closed.fetch("lifecycle")
      assert_equal original.fetch("interval_id"), closed.fetch("interval_id")
      assert_equal "UTC", closed.fetch("time_zone")
    end
  end

  def test_default_clock_materializes_yesterday_and_invalid_dates_fail_cleanly
    with_tmp_global_config do |home|
      config = { "enabled" => true, "time_zone" => "UTC" }
      empty = { "digest" => { "repositories" => [] } }
      writer = Hive::DailyDigest::DocumentWriter.new(
        config_loader: -> { config }, projects_loader: -> { [] },
        store: Hive::DailyDigest::Store.new(root: File.join(home, "documents")),
        facts_loader: ->(**_) { empty }
      )
      before = Time.now.utc.to_date.prev_day.iso8601
      result = writer.refresh.first
      after = Time.now.utc.to_date.prev_day.iso8601
      assert_includes [ before, after ], result.fetch("local_date")
      assert_equal "closed", result.fetch("status")
      assert_raises(Hive::DailyDigest::InvalidRecord) { writer.refresh(date: "invalid") }
    end
  end

  private

  def facts
    { "schema" => "prdigest-facts", "schema_version" => 1, "status" => "success", "digest" => {
      "date" => "2026-09-15", "timezone" => "UTC", "repositories" => [
        { "name" => "ivankuznetsov/hive", "pull_requests" => [
          { "number" => 1, "title" => "Improve loading", "url" => "https://github.com/ivankuznetsov/hive/pull/1",
            "additions" => 120, "deletions" => 30, "commits" => 3,
            "merged_at" => "2026-09-15T12:00:00Z", "description" => "Use the saved snapshot", "files" => [] }
        ] }
      ]
    } }
  end
end
