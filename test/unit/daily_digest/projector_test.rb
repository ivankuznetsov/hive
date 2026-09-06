require "test_helper"
require "hive/daily_digest/projector"
require "hive/daily_digest/calendar"
require "hive/daily_digest/collector"

class DailyDigestProjectorTest < Minitest::Test
  NOW = Time.iso8601("2026-08-30T12:00:00Z")

  def test_builds_orthogonal_base_axes_and_deterministic_amendment
    projector = Hive::DailyDigest::Projector.new(clock: -> { NOW })
    base = projector.base(interval: interval, batch: batch, lifecycle: "closed")

    assert_equal "closed", base.fetch("lifecycle")
    assert_equal "partial", base.fetch("completeness")
    assert_equal "non_empty", base.fetch("content")
    assert_equal NOW.iso8601(6), base.fetch("closed_at")

    recovered = batch(gaps: [], facts: [ fact("first"), fact("late") ])
    amendment = projector.amendment(existing: base.merge(
      "effective_gaps" => base.fetch("gaps"), "amendments" => []
    ), batch: recovered, attempted_gap_ids: [ "gap:one" ])

    assert_equal [ "fact:late" ], amendment.fetch("items").map { |item| item.fetch("fact_id") }
    assert_equal [ "gap:one" ], amendment.fetch("resolved_gap_ids")
    assert_equal [ "gap:one" ], amendment.fetch("resolved_gaps").map { |row| row.fetch("gap_id") }
    assert_equal "github", amendment.fetch("source")
    assert_equal amendment.fetch("amendment_id"),
                 projector.amendment(existing: base.merge(
                   "effective_gaps" => base.fetch("gaps"), "amendments" => []
                 ), batch: recovered, attempted_gap_ids: [ "gap:one" ]).fetch("amendment_id")
  end

  def test_recovery_resolves_only_the_gap_ids_that_were_attempted
    projector = Hive::DailyDigest::Projector.new(clock: -> { NOW })
    github = gap
    registry = gap.merge(
      "gap_id" => "gap:registry", "source" => "registry_history", "scope" => "global"
    )
    existing = projector.base(
      interval: interval, batch: batch(gaps: [ github, registry ], facts: []), lifecycle: "closed"
    ).merge("effective_gaps" => [ github, registry ])

    amendment = projector.amendment(
      existing: existing, batch: batch(gaps: [], facts: []),
      attempted_gap_ids: [ github.fetch("gap_id") ]
    )

    assert_equal [ "gap:one" ], amendment.fetch("resolved_gap_ids")
    assert_equal [ "gap:one" ], amendment.fetch("resolved_gaps").map { |row| row.fetch("gap_id") }
  end

  def test_complete_no_activity_is_explicit_empty
    base = Hive::DailyDigest::Projector.new(clock: -> { NOW }).base(
      interval: interval, batch: batch(gaps: [], facts: []), lifecycle: "open"
    )

    assert_equal "complete", base.fetch("completeness")
    assert_equal "empty", base.fetch("content")
    assert_nil base.fetch("closed_at")
  end

  def test_amendment_deduplicates_attention_and_adds_new_gaps
    projector = Hive::DailyDigest::Projector.new(clock: -> { NOW })
    existing_attention = attention("existing")
    existing = projector.base(
      interval: interval,
      batch: batch(gaps: [], facts: [], attention: [ existing_attention ]),
      lifecycle: "closed"
    ).merge("effective_gaps" => [])
    amendment = projector.amendment(
      existing: existing,
      batch: batch(
        gaps: [ gap ], facts: [],
        attention: [ existing_attention, attention("new") ]
      )
    )

    assert_equal [ "attention:new" ], amendment.fetch("attention").map { |row| row.fetch("attention_id") }
    assert_equal [ "gap:one" ], amendment.fetch("gaps").map { |row| row.fetch("gap_id") }
  end

  private

  def interval
    Hive::DailyDigest::Calendar.new(time_zone: "UTC").interval_for("2026-08-30", sequence: 1)
  end

  def batch(gaps: [ gap ], facts: [ fact("first") ], attention: [])
    Hive::DailyDigest::Collector::Result.new(
      projects: [ { "project_id" => "project-1", "name" => "demo" } ],
      facts: facts, attention: attention, gaps: gaps,
      frontiers: { "project-1" => { "source" => "task_journal", "fingerprints" => [] } },
      completeness: gaps.empty? ? "complete" : "partial",
      content: facts.empty? ? (gaps.empty? ? "empty" : "unknown") : "non_empty"
    )
  end

  def fact(id)
    {
      "fact_id" => "fact:#{id}", "kind" => "stage_transition",
      "project_id" => "project-1", "project" => "demo",
      "task_slug" => "task", "occurred_at" => "2026-08-30T10:00:00.000000Z",
      "observed_at" => "2026-08-30T10:00:01.000000Z"
    }
  end

  def gap
    {
      "gap_id" => "gap:one", "source" => "github", "scope" => "demo",
      "reason_code" => "unavailable", "reason" => "unavailable",
      "observed_at" => NOW.iso8601(6), "freshness_at" => nil,
      "project_id" => "project-1", "task_slug" => nil
    }
  end

  def attention(id)
    {
      "attention_id" => "attention:#{id}", "kind" => "blocked",
      "project_id" => "project-1", "project" => "demo", "task_slug" => id
    }
  end
end
