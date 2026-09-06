require "test_helper"
require "hive/task_workspace/publication_activity"

class TaskWorkspacePublicationActivityTest < Minitest::Test
  class Activity
    attr_reader :records

    def initialize = @records = []
    def record(**attributes) = @records << attributes
  end

  def test_records_only_changed_pr_check_and_review_outcomes
    activity = Activity.new
    observer = Hive::TaskWorkspace::PublicationActivity.new(
      activity: activity, clock: -> { Time.iso8601("2026-08-30T12:00:00Z") }
    )
    before = presented_observation(
      "state" => "OPEN", "is_draft" => true,
      "review_decision" => "REVIEW_REQUIRED",
      "checks" => [ { "name" => "ci", "status" => "IN_PROGRESS", "conclusion" => "" } ]
    )
    after = presented_observation(
      "state" => "OPEN", "is_draft" => false,
      "review_decision" => "APPROVED",
      "checks" => [ { "name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS" } ]
    )

    assert observer.record(before: before, after: after)
    assert_equal %w[check_observed pr_observed review_observed],
                 activity.records.map { |row| row.fetch(:kind) }.sort
    activity.records.each do |row|
      assert_equal 42, row.dig(:payload, "pr_number")
      assert_equal "https://github.com/acme/demo/pull/42", row.dig(:payload, "pr_url")
      refute_includes row.dig(:payload).to_s, "title"
    end

    refute observer.record(before: after, after: after)
    assert_equal 3, activity.records.length
  end

  def test_records_merge_with_known_event_time_and_is_noop_without_activity
    activity = Activity.new
    observer = Hive::TaskWorkspace::PublicationActivity.new(activity: activity)
    merged = presented_observation(
      "state" => "MERGED", "merged_at" => "2026-08-30T11:30:00Z",
      "merge_commit_oid" => "b" * 40
    )

    assert observer.record(before: presented_observation, after: merged)
    row = activity.records.find { |entry| entry.fetch(:kind) == "merge_observed" }
    assert_equal "2026-08-30T11:30:00.000000Z", row.fetch(:occurred_at)
    assert_equal "b" * 40, row.dig(:payload, "merge_oid")

    refute Hive::TaskWorkspace::PublicationActivity.new(activity: nil)
                                                    .record(before: {}, after: merged)
  end

  def test_recurring_outcomes_get_distinct_transition_identities
    activity = Activity.new
    observer = Hive::TaskWorkspace::PublicationActivity.new(activity: activity)
    passing = presented_observation(
      "checks" => [ { "name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS" } ]
    )
    failing = presented_observation(
      "checks" => [ { "name" => "ci", "status" => "COMPLETED", "conclusion" => "FAILURE" } ]
    ).merge("observed_at" => "2026-08-30T12:05:00Z")
    recovered = passing.merge("observed_at" => "2026-08-30T12:10:00Z")

    assert observer.record(before: presented_observation, after: passing)
    assert observer.record(before: passing, after: failing)
    assert observer.record(before: failing, after: recovered)
    refute observer.record(before: recovered, after: recovered)

    identities = activity.records.filter_map do |row|
      row.fetch(:operation_id) if row.fetch(:kind) == "check_observed"
    end
    assert_equal 3, identities.length
    assert_equal identities.length, identities.uniq.length
  end

  def test_defensive_observation_and_check_outcomes_are_closed
    activity = Activity.new
    observer = Hive::TaskWorkspace::PublicationActivity.new(activity: activity)
    assert_nil observer.send(:observation, Object.new)

    none = presented_observation.fetch("observation")
    failing = presented_observation(
      "checks" => [ { "status" => "COMPLETED", "conclusion" => "FAILURE" } ]
    ).fetch("observation")
    pending = presented_observation(
      "checks" => [ { "status" => "IN_PROGRESS", "conclusion" => nil } ]
    ).fetch("observation")
    assert_equal "none", observer.send(:check_payload, none).fetch("check_state")
    assert_equal "failing", observer.send(:check_payload, failing).fetch("check_state")
    assert_equal "pending", observer.send(:check_payload, pending).fetch("check_state")

    activity.define_singleton_method(:record) do |**|
      raise Hive::TaskActivity::AppendFailed, "journal unavailable"
    end
    refute observer.record(before: nil, after: presented_observation("state" => "CLOSED"))
  end

  private

  def presented_observation(overrides = {})
    {
      "state" => "current", "observed_at" => "2026-08-30T12:00:00Z",
      "observation" => {
        "repository" => "github.com/acme/demo", "number" => 42,
        "url" => "https://github.com/acme/demo/pull/42", "state" => "OPEN",
        "is_draft" => true, "head_oid" => "a" * 40,
        "review_decision" => "REVIEW_REQUIRED", "checks" => [],
        "merged_at" => nil, "merge_commit_oid" => nil
      }.merge(overrides)
    }
  end
end
