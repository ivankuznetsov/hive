require "test_helper"
require "hive/daily_digest/coordinator"

class DailyDigestLifecycleTest < Minitest::Test
  include HiveTestHelper

  FakeCollector = Struct.new(:result) do
    def collect = result
  end

  def test_partial_close_recovers_with_amendment_and_keeps_base_bytes_stable
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-31T12:00:00Z")
      gap = {
        "gap_id" => "gap:github", "source" => "github", "scope" => "demo",
        "reason_code" => "unavailable", "reason" => "GitHub unavailable",
        "observed_at" => "2026-08-31T00:00:00Z", "freshness_at" => nil,
        "project_id" => "project-1", "task_slug" => "task"
      }
      current = batch(facts: [], gaps: [ gap ])
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = Hive::DailyDigest::Coordinator.new(
        config_loader: -> { config("UTC") }, history_loader: -> { [] }, store: store,
        collector_factory: ->(**) { FakeCollector.new(current) }, clock: -> { now }
      )

      coordinator.refresh(date: "2026-08-30")
      first = store.read("2026-08-30")
      bytes = File.binread(store.base_path("2026-08-30"))
      assert_equal "partial", first.fetch("effective_completeness")
      assert_equal "unknown", first.fetch("effective_content")

      current = batch(facts: [ fact("recovered") ], gaps: [])
      coordinator.refresh(date: "2026-08-30")
      recovered = store.read("2026-08-30")

      assert_equal bytes, File.binread(store.base_path("2026-08-30"))
      assert_equal "complete", recovered.fetch("effective_completeness")
      assert_equal "non_empty", recovered.fetch("effective_content")
      assert_equal [ "gap:github" ], recovered.fetch("amendments").first.fetch("resolved_gap_ids")
    end
  end

  def test_zone_change_starts_next_sequence_at_prior_fixed_end
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-31T12:00:00Z")
      zone = "UTC"
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = Hive::DailyDigest::Coordinator.new(
        config_loader: -> { config(zone) }, history_loader: -> { [] }, store: store,
        collector_factory: ->(**) { FakeCollector.new(batch(facts: [], gaps: [])) },
        clock: -> { now }
      )
      coordinator.refresh(date: "2026-08-30")
      original = store.read("2026-08-30")
      original_bytes = File.binread(store.base_path("2026-08-30"))

      zone = "Pacific/Kiritimati"
      coordinator.refresh
      following = store.intervals.find { |interval| interval.fetch("sequence") == 2 }

      assert_equal original.fetch("ends_at"), following.fetch("starts_at")
      assert_equal "zone_cutover", following.fetch("boundary_kind")
      assert_equal original_bytes, File.binread(store.base_path("2026-08-30"))
    end
  end

  private

  def config(zone)
    first = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                       .interval_for("2026-08-30", sequence: 1)
    {
      "enabled" => true, "time_zone" => zone,
      "coverage_started_at" => "2026-08-30T00:00:00Z",
      "initial_membership" => [ project ], "first_interval" => first,
      "freshness_budget_sec" => 900
    }
  end

  def project
    {
      "project_id" => "project-1", "registration_id" => "registration-1",
      "name" => "demo", "path" => "/demo", "hive_state_path" => "/demo/.hive-state"
    }
  end

  def batch(facts:, gaps:)
    Hive::DailyDigest::Collector::Result.new(
      projects: [ project ], facts: facts, attention: [], gaps: gaps,
      frontiers: {
        "project-1" => {
          "source" => "task_journal",
          "fingerprints" => {
            "4-execute/task/task-journal.jsonl" => { "sha256" => "a" * 64 }
          }
        }
      },
      completeness: gaps.empty? ? "complete" : "partial",
      content: facts.empty? ? (gaps.empty? ? "empty" : "unknown") : "non_empty"
    )
  end

  def fact(id)
    {
      "fact_id" => "fact:#{id}", "kind" => "pr_observed",
      "project_id" => "project-1", "project" => "demo", "task_slug" => "task",
      "source" => "github", "occurred_at" => "2026-08-30T10:00:00Z",
      "observed_at" => "2026-08-31T10:00:00Z"
    }
  end
end
