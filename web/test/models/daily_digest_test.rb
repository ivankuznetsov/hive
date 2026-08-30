require "test_helper"

class DailyDigestTest < ActiveSupport::TestCase
  test "reads one persisted view and strips question content before presentation" do
    calls = []
    reader = Object.new
    view = raw_view
    reader.define_singleton_method(:read) do |**options|
      calls << options
      view
    end
    destinations = []
    resolver = lambda do |project, row|
      destinations << [ project, row ]
      { project: "alpha", slug: "waiting-task", source: nil }
    end

    digest = DailyDigest.find(
      date: "2026-08-30", project: "alpha", reader: reader,
      link_resolver: resolver
    )

    assert_equal [ { date: "2026-08-30", project: "alpha" } ], calls
    attention = digest.attention.first
    assert_equal "waiting-task", attention.fetch("task_slug")
    assert_equal({ project: "alpha", slug: "waiting-task", source: nil },
                 attention.fetch("task_destination"))
    refute attention.key?("question")
    refute attention.key?("binding")
    refute_includes digest.attributes.to_json, "private question"
    refute_includes digest.attributes.to_json, "secret binding"
    assert_equal 1, destinations.length
  end

  test "recursively strips non-public item gap and amendment fields" do
    view = raw_view
    view["projects"][0]["path"] = "/private/project"
    view["items"][0]["payload"] = "private item"
    view["items"][0]["details"] = { "to_stage" => "3-plan", "prompt" => "private detail" }
    view["gaps"] = view["effective_gaps"] = [ {
      "gap_id" => "gap:one", "source" => "github", "scope" => "alpha",
      "reason_code" => "offline", "reason" => "offline",
      "observed_at" => "2026-08-30T20:00:00Z", "freshness_at" => nil,
      "payload" => "private gap"
    } ]
    view["amendments"] = [ {
      "amendment_id" => "amendment:one", "kind" => "gap_resolution",
      "source" => "github", "event_at" => nil,
      "observed_at" => "2026-08-31T08:00:00Z",
      "amended_at" => "2026-08-31T08:00:01Z", "payload" => "private amendment",
      "items" => view["items"], "attention" => view["attention"], "gaps" => [],
      "resolved_gap_ids" => [ "gap:one" ], "resolved_gaps" => view["gaps"]
    } ]

    digest = DailyDigest.new(
      view, requested_date: "2026-08-30",
      link_resolver: ->(_project, _row) { nil }, current_projects: []
    )

    serialized = digest.attributes.to_json
    [ "/private/project", "private item", "private detail", "private gap",
      "private amendment", "private question", "secret binding" ].each do |secret|
      refute_includes serialized, secret
    end
    assert_equal "3-plan", digest.items.first.dig("details", "to_stage")
    assert_equal [ "gap:one" ], digest.amendments.first.fetch("resolved_gap_ids")
  end

  test "recovery command never turns the current identity into an invalid date flag" do
    today = DailyDigest.new(
      { "reader_status" => "missing", "local_date" => nil }, requested_date: "today"
    )
    historical = DailyDigest.new(
      { "reader_status" => "missing", "local_date" => "2026-08-29" },
      requested_date: "2026-08-29"
    )

    assert_equal "hive digest refresh", today.refresh_command
    assert_equal "hive digest refresh --date 2026-08-29", historical.refresh_command
  end

  test "retains historical projects but refuses unsafe PR and unresolved task links" do
    reader = Object.new
    view = raw_view
    view["projects"] << {
      "project_id" => "old", "registration_id" => "old-registration",
      "name" => "removed-project"
    }
    view["items"][0]["pr"] = {
      "number" => 7, "url" => "javascript:alert(1)"
    }
    reader.define_singleton_method(:read) { |**| view }

    digest = DailyDigest.find(
      date: "2026-08-30", reader: reader,
      link_resolver: ->(_project, _row) { nil }, current_projects: []
    )

    assert_equal %w[alpha removed-project], digest.projects.map { |project| project.fetch("name") }
    assert digest.historical_project?(digest.projects.last)
    assert_nil digest.task_destination(digest.items.first)
    assert_nil digest.pr_url(digest.items.first)
  end

  def self.raw_view
    {
      "reader_status" => "ok", "record_id" => "record-1",
      "local_date" => "2026-08-30", "sequence" => 1,
      "time_zone" => "Europe/London", "starts_at" => "2026-08-29T23:00:00Z",
      "ends_at" => "2026-08-30T23:00:00Z", "boundary_kind" => "calendar_day",
      "lifecycle" => "closed", "closed_at" => "2026-08-30T23:01:00Z",
      "completeness" => "complete", "effective_completeness" => "complete",
      "content" => "non_empty", "effective_content" => "non_empty",
      "last_materialized_at" => "2026-08-30T23:01:00Z", "stale" => false,
      "selected_project" => "alpha", "previous_date" => nil, "next_date" => nil,
      "projects" => [
        { "project_id" => "alpha-id", "registration_id" => "alpha-registration", "name" => "alpha" }
      ],
      "attention" => [
        {
          "attention_id" => "attention-1", "kind" => "unanswered",
          "project_id" => "alpha-id", "project" => "alpha", "task_id" => 42,
          "task_slug" => "waiting-task", "stage" => "2-brainstorm", "state" => "waiting",
          "waiting_since" => "2026-08-30T20:00:00Z", "waiting_age_seconds" => 10_800,
          "question" => "private question", "binding" => "secret binding"
        }
      ],
      "items" => [
        {
          "fact_id" => "fact-1", "kind" => "stage_transition", "category" => "progress",
          "summary" => "Task stage changed", "project_id" => "alpha-id", "project" => "alpha",
          "task_id" => 42, "task_slug" => "waiting-task", "stage" => "2-brainstorm",
          "occurred_at" => "2026-08-30T19:00:00Z", "observed_at" => "2026-08-30T19:00:01Z",
          "source" => "task_journal", "details" => {}
        }
      ],
      "gaps" => [], "effective_gaps" => [], "amendments" => []
    }
  end

  def raw_view
    JSON.parse(JSON.generate(self.class.raw_view))
  end
end
