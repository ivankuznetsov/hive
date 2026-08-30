require "test_helper"
require "hive/daily_digest/coordinator"

class DailyDigestCoordinatorTest < Minitest::Test
  include HiveTestHelper

  def test_refresh_opens_closes_catches_up_and_amends_without_rewriting_closed_base
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      facts = [ fact("first", "2026-08-30T10:00:00Z") ]
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = build_coordinator(store, -> { now }, -> { facts })

      first = coordinator.refresh
      assert_equal [ "2026-08-30" ], first.map { |row| row.fetch("local_date") }
      assert_equal "open", store.read("2026-08-30").fetch("lifecycle")

      now = Time.iso8601("2026-09-01T12:00:00Z")
      coordinator.refresh
      assert_equal "closed", store.read("2026-08-30").fetch("lifecycle")
      assert_equal "closed", store.read("2026-08-31").fetch("lifecycle")
      assert_equal "open", store.read("2026-09-01").fetch("lifecycle")
      closed_bytes = File.binread(store.base_path("2026-08-30"))

      facts << fact("late", "2026-08-30T11:00:00Z")
      coordinator.refresh(date: "2026-08-30")
      historical = store.read("2026-08-30")
      assert_equal closed_bytes, File.binread(store.base_path("2026-08-30"))
      assert_equal [ "fact:first", "fact:late" ],
                   historical.fetch("items").map { |item| item.fetch("fact_id") }.sort
      assert_equal 1, historical.fetch("amendments").size

      coordinator.refresh(date: "2026-08-30")
      assert_equal closed_bytes, File.binread(store.base_path("2026-08-30"))
      assert_equal 1, store.read("2026-08-30").fetch("amendments").size
    end
  end

  def test_crash_before_store_commit_replays_same_fact_once
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      facts = [ fact("first", "2026-08-30T10:00:00Z") ]
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      calls = 0
      collector = lambda do |**|
        calls += 1
        raise "crash after collection" if calls == 1

        FakeCollector.new(batch(facts))
      end
      coordinator = Hive::DailyDigest::Coordinator.new(
        config_loader: -> { config }, history_loader: -> { [] }, store: store,
        collector_factory: collector, clock: -> { now }
      )

      assert_raises(RuntimeError) { coordinator.refresh }
      assert_raises(Hive::DailyDigest::MissingRecord) { store.read("2026-08-30") }
      coordinator.refresh
      assert_equal [ "fact:first" ], store.read("2026-08-30").fetch("items").map { |item| item.fetch("fact_id") }
    end
  end

  def test_pruned_target_records_discard_and_frontier_without_recreation
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-31T12:00:00Z")
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = build_coordinator(store, -> { now }, -> { [ fact("first", "2026-08-30T10:00:00Z") ] })
      coordinator.refresh(date: "2026-08-30")
      store.prune("2026-08-30", pruned_at: now, reason: "test")

      coordinator.refresh(date: "2026-08-30")
      tombstone = store.read("2026-08-30")
      assert_equal "pruned", tombstone.fetch("lifecycle")
      assert_equal [ "fact:first" ], tombstone.fetch("discards").map { |row| row.fetch("identity") }
      refute File.exist?(store.base_path("2026-08-30"))
    end
  end

  private

  FakeCollector = Struct.new(:result) do
    def collect = result
  end

  def build_coordinator(store, clock, facts)
    Hive::DailyDigest::Coordinator.new(
      config_loader: -> { config }, history_loader: -> { [] }, store: store,
      collector_factory: ->(**) { FakeCollector.new(batch(facts.call)) }, clock: clock
    )
  end

  def config
    calendar = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
    {
      "enabled" => true, "time_zone" => "UTC",
      "coverage_started_at" => "2026-08-30T00:00:00.000000Z",
      "initial_membership" => [ project ],
      "first_interval" => calendar.interval_for("2026-08-30", sequence: 1),
      "freshness_budget_sec" => 900
    }
  end

  def project
    {
      "project_id" => "project-1", "registration_id" => "registration-1",
      "name" => "demo", "path" => "/demo", "hive_state_path" => "/demo/.hive-state"
    }
  end

  def batch(facts)
    Hive::DailyDigest::Collector::Result.new(
      projects: [ project ], facts: facts, attention: [], gaps: [],
      frontiers: { "project-1" => { "source" => "task_journal", "fingerprints" => facts.map { |f| f["fact_id"] } } },
      completeness: "complete", content: facts.empty? ? "empty" : "non_empty"
    )
  end

  def fact(id, occurred_at)
    {
      "fact_id" => "fact:#{id}", "kind" => "stage_transition",
      "project_id" => "project-1", "project" => "demo", "task_slug" => "task",
      "occurred_at" => Time.iso8601(occurred_at).utc.iso8601(6),
      "observed_at" => Time.iso8601(occurred_at).utc.iso8601(6)
    }
  end
end
