require "test_helper"
require "hive/daily_digest/coverage"

class DailyDigestCoverageTest < Minitest::Test
  def test_selects_every_membership_that_overlaps_an_interval
    coverage = Hive::DailyDigest::Coverage.new(
      daily_config: {
        "coverage_started_at" => "2026-08-30T00:00:00Z",
        "initial_membership" => [ project("old", "/old") ]
      },
      membership_history: [
        event("replaced", "2026-08-30T12:00:00Z",
              before: project("old", "/old"), after: project("new", "/new")),
        event("unregistered", "2026-08-31T00:00:00Z",
              before: project("new", "/new"), after: nil)
      ],
      observed_at: -> { Time.iso8601("2026-08-31T01:00:00Z") }
    )

    result = coverage.projects_for(
      starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
      ends_at: Time.iso8601("2026-08-31T00:00:00Z")
    )

    assert_equal %w[/new /old], result.projects.map { |row| row.fetch("path") }.sort
    assert_empty result.gaps
  end

  def test_malformed_history_returns_a_gap_instead_of_claiming_completeness
    coverage = Hive::DailyDigest::Coverage.new(
      daily_config: {
        "coverage_started_at" => "2026-08-30T00:00:00Z",
        "initial_membership" => [ project("old", "/old") ]
      },
      membership_history: [ { "kind" => "replaced", "occurred_at" => "bad" } ],
      observed_at: -> { Time.iso8601("2026-08-31T01:00:00Z") }
    )

    result = coverage.projects_for(
      starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
      ends_at: Time.iso8601("2026-08-31T00:00:00Z")
    )

    assert_equal [ "registry_history_invalid" ], result.gaps.map { |gap| gap.fetch("reason_code") }
  end

  def test_precoverage_interval_is_typed_missing
    coverage = Hive::DailyDigest::Coverage.new(
      daily_config: {
        "coverage_started_at" => "2026-08-30T10:00:00Z",
        "initial_membership" => []
      }, membership_history: []
    )

    assert_raises(Hive::DailyDigest::Coverage::PreCoverage) do
      coverage.projects_for(
        starts_at: Time.iso8601("2026-08-29T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-30T00:00:00Z")
      )
    end
  end

  def test_invalid_snapshot_and_history_discontinuities_become_deduplicated_gaps
    original = project("old", "/old")
    replacement_before = original.merge("path" => "/moved", "hive_state_path" => "/moved/.hive-state")
    coverage = Hive::DailyDigest::Coverage.new(
      daily_config: {
        "coverage_started_at" => "2026-08-30T00:00:00Z",
        "initial_membership" => [ {}, original ]
      },
      membership_history: [
        event("registered", "2026-08-30T00:00:00Z", before: original, after: original),
        event("replaced", "2026-08-30T01:00:00Z",
              before: replacement_before, after: project("new", "/new")),
        event("unregistered", "2026-08-30T02:00:00Z",
              before: project("ghost", "/ghost").merge("project_id" => "ghost-project"),
              after: nil)
      ]
    )

    result = coverage.projects_for(
      starts_at: "2026-08-30T03:00:00Z", ends_at: "2026-08-30T04:00:00Z"
    )
    codes = result.gaps.map { |gap| gap.fetch("reason_code") }
    assert_includes codes, "registry_snapshot_invalid"
    assert_includes codes, "registry_history_invalid"
    assert_includes codes, "registry_history_discontinuous"
    assert_equal [ "/new" ], result.projects.map { |row| row.fetch("path") }
  end

  def test_missing_coverage_configuration_is_a_typed_invalid_record
    coverage = Hive::DailyDigest::Coverage.new(
      daily_config: { "initial_membership" => [] }, membership_history: []
    )
    assert_raises(Hive::DailyDigest::InvalidRecord) do
      coverage.projects_for(starts_at: "2026-08-30T00:00:00Z",
                            ends_at: "2026-08-31T00:00:00Z")
    end
  end

  private

  def project(registration, path)
    {
      "name" => "demo", "project_id" => "project-1",
      "registration_id" => registration, "path" => path,
      "hive_state_path" => "#{path}/.hive-state"
    }
  end

  def event(kind, at, before:, after:)
    {
      "schema" => "hive-project-membership", "schema_version" => 1,
      "event_id" => "event-#{at}", "kind" => kind,
      "occurred_at" => at, "before" => before, "after" => after
    }
  end
end
