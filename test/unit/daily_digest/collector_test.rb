require "test_helper"
require "hive/daily_digest/collector"

class DailyDigestCollectorTest < Minitest::Test
  include HiveTestHelper

  def test_no_known_activity_is_unknown_when_a_source_fails_and_empty_when_healthy
    project = { "project_id" => "one", "name" => "one" }
    failing = lambda do |**|
      Object.new.tap do |source|
        source.define_singleton_method(:collect) do
          raise Hive::DailyDigest::ProjectSource::SourceUnavailable, "offline"
        end
      end
    end
    partial = Hive::DailyDigest::Collector.new(
      projects: [ project ], starts_at: Time.at(0), ends_at: Time.at(1),
      source_factory: failing
    ).collect
    assert_equal "partial", partial.completeness
    assert_equal "unknown", partial.content

    empty = Hive::DailyDigest::Collector.new(
      projects: [], starts_at: Time.at(0), ends_at: Time.at(1)
    ).collect
    assert_equal "complete", empty.completeness
    assert_equal "empty", empty.content
  end


  def test_successful_sources_are_combined_deduplicated_and_sorted
    project = { "project_id" => "one", "registration_id" => "r1", "name" => "one" }
    later = fact("later", "2026-08-30T11:00:00Z")
    earlier = fact("earlier", "2026-08-30T09:00:00Z")
    gap = Hive::DailyDigest::Materiality.build_gap(
      source: "github", scope: "one", reason_code: "offline", reason: "offline",
      observed_at: "2026-08-30T12:00:00Z", project_id: "one"
    )
    result = Hive::DailyDigest::ProjectSource::Result.new(
      project: project, facts: [ later, earlier, later ],
      attention: [ { "attention_id" => "attention:one", "project_id" => "one" } ],
      gaps: [ gap, gap ], frontier: { "cursor" => 1 },
      health: Hive::DailyDigest::SourceHealth.healthy(source: "project_state", scope: "one")
    )
    source = Object.new
    source.define_singleton_method(:collect) { result }

    with_replaced_singleton_method(
      Hive::DailyDigest::ProjectSource, :new, ->(**) { source }
    ) do
      collected = Hive::DailyDigest::Collector.new(
        projects: [ project ], starts_at: Time.at(0), ends_at: Time.at(1)
      ).collect

      assert_equal %w[earlier later], collected.facts.map { |row| row.fetch("fact_id") }
      assert_equal [ "attention:one" ], collected.attention.map { |row| row.fetch("attention_id") }
      assert_equal [ gap.fetch("gap_id") ], collected.gaps.map { |row| row.fetch("gap_id") }
      assert_equal(
        {
          "one:r1" => {
            "cursor" => 1, "project_id" => "one", "registration_id" => "r1"
          }
        },
        collected.frontiers
      )
      assert_equal "non_empty", collected.content
    end
  end

  def test_replaced_registration_does_not_reuse_the_previous_source_frontier
    old = { "project_id" => "one", "registration_id" => "old", "name" => "one" }
    replacement = old.merge("registration_id" => "new")
    seen = []
    factory = lambda do |project:, prior_frontier:, **|
      seen << [ project.fetch("registration_id"), prior_frontier ]
      result = Hive::DailyDigest::ProjectSource::Result.new(
        project: project, facts: [], attention: [], gaps: [],
        frontier: {
          "project_id" => project.fetch("project_id"),
          "registration_id" => project.fetch("registration_id"),
          "fingerprints" => {}
        },
        health: Hive::DailyDigest::SourceHealth.healthy(source: "project_state", scope: "one")
      )
      Object.new.tap { |source| source.define_singleton_method(:collect) { result } }
    end

    collected = Hive::DailyDigest::Collector.new(
      projects: [ old, replacement ], starts_at: Time.at(0), ends_at: Time.at(1),
      prior_frontiers: {
        "one:old" => { "fingerprints" => { "old" => true } }
      }, source_factory: factory
    ).collect

    assert_equal [
      [ "old", { "fingerprints" => { "old" => true } } ],
      [ "new", nil ]
    ], seen
    assert_equal %w[one:new one:old], collected.frontiers.keys.sort
  end

  def test_frontier_lookup_handles_embedded_legacy_and_malformed_shapes
    embedded = {
      "opaque" => { "project_id" => "one", "registration_id" => "current", "cursor" => 3 }
    }
    assert_equal 3, Hive::DailyDigest::Collector.frontier_for(
      embedded, project_id: "one", registration_id: "current"
    ).fetch("cursor")

    mismatched = {
      "one" => { "project_id" => "one", "registration_id" => "old", "cursor" => 1 }
    }
    assert_nil Hive::DailyDigest::Collector.frontier_for(
      mismatched, project_id: "one", registration_id: "current"
    )

    unbound_legacy = { "one" => { "project_id" => "one", "cursor" => 2 } }
    assert_equal 2, Hive::DailyDigest::Collector.frontier_for(
      unbound_legacy, project_id: "one", registration_id: "current"
    ).fetch("cursor")
    assert_nil Hive::DailyDigest::Collector.frontier_for(Object.new, project_id: "one")
  end

  private

  def fact(id, occurred_at)
    {
      "fact_id" => id, "kind" => "changed", "project_id" => "one", "project" => "one",
      "occurred_at" => occurred_at, "observed_at" => occurred_at
    }
  end
end
