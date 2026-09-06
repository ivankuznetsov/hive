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
      assert_equal({ "one" => { "cursor" => 1 } }, collected.frontiers)
      assert_equal "non_empty", collected.content
    end
  end

  private

  def fact(id, occurred_at)
    {
      "fact_id" => id, "kind" => "changed", "project_id" => "one", "project" => "one",
      "occurred_at" => occurred_at, "observed_at" => occurred_at
    }
  end
end
