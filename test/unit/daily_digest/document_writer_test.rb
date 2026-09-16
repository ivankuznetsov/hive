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

  private

  def facts
    { "schema" => "prdigest-facts", "schema_version" => 1, "status" => "success", "digest" => {
      "date" => "2026-09-15", "timezone" => "UTC", "repositories" => [
        { "name" => "ivankuznetsov/hive", "pull_requests" => [
          { "number" => 1, "title" => "Improve loading", "url" => "https://github.com/ivankuznetsov/hive/pull/1",
            "merged_at" => "2026-09-15T12:00:00Z", "description" => "Use the saved snapshot", "files" => [] }
        ] }
      ]
    } }
  end
end
