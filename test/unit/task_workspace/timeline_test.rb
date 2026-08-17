require "test_helper"
require "hive/task_workspace/timeline"
require "json_schemer"

class TaskWorkspaceTimelineTest < Minitest::Test
  SECRET = "timeline-test-secret-that-is-at-least-thirty-two-bytes".freeze

  def test_authoritative_duplicate_wins_and_same_timestamp_order_is_stable
    journal = [
      activity("event-b", "answer_recorded", at: "2026-08-12T12:00:00Z",
               correlation: "answer-1", reason: "Answer recorded"),
      activity("event-a", "question_asked", at: "2026-08-12T12:00:00Z",
               correlation: "question-1", reason: "Question asked")
    ]
    telemetry = [
      event("telemetry-answer", "answer_recorded", at: "2026-08-12T12:00:00Z",
            correlation: "answer-1")
    ]

    first = timeline(journal: journal, events: telemetry).call
    second = timeline(journal: journal.reverse, events: telemetry.reverse).call

    assert_equal first.fetch("records"), second.fetch("records")
    assert_equal %w[answer_recorded question_asked],
                 first.fetch("records").map { |row| row.fetch("kind") }
    answer = first.fetch("records").first
    assert_equal "task_journal", answer.fetch("source")
    assert answer.fetch("cross_source_duplicate")
    assert_equal %w[event-b telemetry-answer], answer.fetch("source_refs")
  end

  def test_external_clock_outside_skew_orders_by_ingestion_and_retains_display_time
    inside = event(
      "inside", "pr_observed", at: "2026-08-12T12:04:00Z",
      ingested_at: "2026-08-12T12:00:00Z", source: "github"
    )
    outside = event(
      "outside", "check_observed", at: "2026-08-13T12:00:00Z",
      ingested_at: "2026-08-12T11:59:00Z", source: "github"
    )

    records = timeline(events: [ inside, outside ]).call.fetch("records")

    assert_equal %w[inside outside], records.map { |row| row.fetch("event_id") }
    refute records.first.fetch("external_clock_unverified")
    assert records.last.fetch("external_clock_unverified")
    assert_equal "2026-08-13T12:00:00.000000Z", records.last.fetch("occurred_at")
    assert_equal "2026-08-12T11:59:00.000000Z", records.last.fetch("ordering_at")
  end

  def test_noise_has_separate_budget_groups_in_sixty_second_windows_and_expands_bounded_raw
    events = 8.times.map do |index|
      event(
        "heartbeat-#{index}", "heartbeat",
        at: (Time.utc(2026, 8, 12, 12) + (index * 10)).iso8601
      )
    end
    events << event("material", "stage_exit", at: "2026-08-12T12:02:00Z")
    limits = Hive::TaskWorkspace::Limits.new(
      timeline_material_items: 1, timeline_noise_groups: 5, timeline_raw_members: 3
    )

    panel = timeline(events: events, limits: limits).call

    assert_equal [ "material" ], panel.fetch("records").map { |row| row.fetch("event_id") }
    groups = panel.fetch("noise_groups")
    assert_equal 2, groups.length
    assert_equal [ 1, 7 ], groups.map { |group| group.fetch("count") }.sort
    large_group = groups.max_by { |group| group.fetch("count") }
    expanded = timeline(events: events, limits: limits).call(
      raw_cursor: large_group.fetch("raw_cursor")
    )
    assert_equal 3, expanded.fetch("records").length
    assert expanded.fetch("truncated")
    assert_equal 7, expanded.fetch("observed_count")
  end

  def test_material_cursor_is_bounded_task_bound_and_tamper_evident
    records = 5.times.map do |index|
      activity(
        "event-#{index}", "stage_transition",
        at: (Time.utc(2026, 8, 12, 12) + index).iso8601,
        correlation: "transition-#{index}"
      )
    end
    limits = Hive::TaskWorkspace::Limits.new(timeline_material_items: 2)
    projector = timeline(journal: records, limits: limits)

    first = projector.call
    second = projector.call(cursor: first.fetch("older_cursor"))
    third = projector.call(cursor: second.fetch("older_cursor"))

    ids = first.fetch("records") + second.fetch("records") + third.fetch("records")
    assert_equal 5, ids.map { |row| row.fetch("event_id") }.uniq.length
    assert_nil third.fetch("older_cursor")
    assert_raises(Hive::TaskWorkspace::Timeline::InvalidCursor) do
      projector.call(cursor: "#{first.fetch('older_cursor')}x")
    end
    other = timeline(
      journal: records, limits: limits,
      task_identity: { "project" => "other", "slug" => "task" }
    )
    assert_raises(Hive::TaskWorkspace::Timeline::InvalidCursor) do
      other.call(cursor: first.fetch("older_cursor"))
    end
  end

  def test_correction_preserves_supersession_and_malformed_records_only_make_panel_partial
    correction = activity(
      "correction-1", "correction", at: "2026-08-12T12:00:00Z",
      supersedes: "event-old", reason: "Corrected clock"
    )
    panel = timeline(
      journal: [
        correction,
        {
          "event_type" => "activity_recorded", "occurred_at" => "bad",
          "payload" => { "activity_kind" => "stage_transition" }
        }
      ]
    ).call

    assert_equal "partial", panel.fetch("state")
    assert_equal "event-old", panel.fetch("records").first.fetch("supersedes_event_id")
    assert_includes panel.fetch("diagnostics").map { |row| row.fetch("reason") },
                    "invalid_timestamp"
  end

  def test_material_and_noise_caps_report_exact_cap_names
    limits = Hive::TaskWorkspace::Limits.new(
      timeline_material_items: 1, timeline_noise_groups: 1
    )
    events = [
      event("m1", "stage_enter", at: "2026-08-12T12:00:00Z"),
      event("m2", "stage_exit", at: "2026-08-12T12:01:00Z"),
      event("n1", "heartbeat-a", at: "2026-08-12T12:00:00Z"),
      event("n2", "heartbeat-b", at: "2026-08-12T12:01:00Z")
    ]

    panel = timeline(events: events, limits: limits).call
    caps = panel.fetch("diagnostics").filter_map { |row| row["cap"] }

    assert_equal "partial", panel.fetch("state")
    assert_includes caps, "timeline_material_items"
    assert_includes caps, "timeline_noise_groups"
  end

  def test_byte_truncation_keeps_an_older_material_cursor
    records = 3.times.map do |index|
      activity(
        "event-#{index}", "stage_transition",
        at: (Time.utc(2026, 8, 12, 12) + index).iso8601,
        correlation: "transition-#{index}", reason: "x" * 300
      )
    end
    limits = Hive::TaskWorkspace::Limits.new(
      timeline_material_items: 10, timeline_bytes: 1_000
    )

    panel = timeline(journal: records, limits: limits).call

    assert panel.fetch("truncated")
    refute_nil panel.fetch("older_cursor")
  end

  def test_noise_group_cursor_stays_decodable_for_large_groups
    events = 2_000.times.map do |index|
      event("heartbeat-#{index}-#{'x' * 200}", "heartbeat", at: "2026-08-12T12:00:00Z")
    end
    projector = timeline(events: events)
    group = projector.call.fetch("noise_groups").first

    assert_operator group.fetch("raw_cursor").bytesize, :<,
                    Hive::TaskWorkspace::Timeline::CursorCodec::MAX_TOKEN_BYTES
    assert_equal 20, projector.call(raw_cursor: group.fetch("raw_cursor")).fetch("records").length
  end

  def test_material_cursor_carries_source_window_boundaries
    newest = Hive::TaskWorkspace::Timeline.new(
      task_identity: { "project" => "demo", "slug" => "task", "task_id" => "42" },
      journal_records: [ activity("new", "stage_transition", at: "2026-08-12T12:01:00Z") ],
      event_records: [], source_positions: { "task_journal" => 512 },
      source_truncated: { "task_journal" => true },
      limits: Hive::TaskWorkspace::Limits.new(timeline_material_items: 10),
      cursor_codec: Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET)
    )
    first = newest.call

    assert_equal({ "task_journal" => 512 }, newest.source_before(first.fetch("older_cursor")))
  end

  def test_material_cursor_replays_a_physical_window_before_advancing_it
    records = 5.times.map do |index|
      activity("event-#{index}", "stage_transition",
               at: (Time.utc(2026, 8, 12, 12) + index).iso8601)
    end
    projector = Hive::TaskWorkspace::Timeline.new(
      task_identity: { "project" => "demo", "slug" => "task", "task_id" => "42" },
      journal_records: records, event_records: [],
      source_positions: { "task_journal" => { "start" => 100, "end" => 200 } },
      source_truncated: { "task_journal" => true },
      limits: Hive::TaskWorkspace::Limits.new(timeline_material_items: 2),
      cursor_codec: Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET)
    )

    first = projector.call
    second = projector.call(cursor: first.fetch("older_cursor"))
    third = projector.call(cursor: second.fetch("older_cursor"))

    assert_equal({ "task_journal" => 200 }, projector.source_before(first.fetch("older_cursor")))
    assert_equal({ "task_journal" => 200 }, projector.source_before(second.fetch("older_cursor")))
    assert_equal({ "task_journal" => 100 }, projector.source_before(third.fetch("older_cursor")))

    late = activity("late", "stage_transition", at: "2026-08-13T12:00:00Z")
    older_window = timeline(journal: [ late ], limits: Hive::TaskWorkspace::Limits.new(
      timeline_material_items: 2
    ))
    assert_equal "late", older_window.call(cursor: third.fetch("older_cursor"))
                                     .dig("records", 0, "event_id")
  end

  def test_hostile_event_fields_are_normalized_to_the_registered_record_schema
    huge = "/home/operator/" + ("x" * 10_000)
    events = 101.times.map do |index|
      event("duplicate-#{index}", "stage_exit", at: "2026-08-12T12:00:00Z",
            correlation: "same").merge(
        "stage" => [ "invalid" ], "attempt_id" => { "invalid" => true },
        "task_generation" => 1.5, "source" => huge,
        "operation_id" => huge
      )
    end
    panel = timeline(events: events).call
    record = panel.fetch("records").first

    assert_nil record.fetch("stage")
    assert_nil record.fetch("attempt_id")
    assert_nil record.fetch("task_generation")
    assert_operator record.fetch("source_refs").length, :<=, 100
    refute_includes JSON.generate(record), "/home/operator"

    document = Hive::TaskWorkspace::Snapshot.new(
      generated_at: "2026-08-12T12:00:00Z",
      task: { "project" => "demo", "slug" => "task", "id" => 42,
              "stage" => "4-execute", "generation" => 1 },
      status: { "state" => "current", "freshness" => "fresh",
                "observed_at" => "2026-08-12T12:00:00Z", "diagnostics" => [] },
      decision: { "posture" => "investigate", "reason" => nil,
                  "action" => { "kind" => nil, "label" => nil,
                                "enabled" => false, "reason" => nil } },
      panels: { "timeline" => panel }
    ).to_h
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 1)))
    )
    assert schemer.valid?(document), schemer.validate(document).to_a.inspect
  end

  private

  def timeline(journal: [], events: [], limits: Hive::TaskWorkspace::Limits.new,
               task_identity: { "project" => "demo", "slug" => "task", "task_id" => "42" })
    Hive::TaskWorkspace::Timeline.new(
      task_identity: task_identity, journal_records: journal,
      event_records: events, limits: limits,
      cursor_codec: Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET)
    )
  end

  def activity(id, kind, at:, correlation: nil, supersedes: nil, reason: nil)
    {
      "schema" => "hive-task-journal-event", "schema_version" => 1,
      "event_id" => id, "event_type" => "activity_recorded",
      "occurred_at" => at, "observed_at" => at,
      "stage" => "4-execute", "attempt_id" => "attempt-1",
      "task_generation" => 3, "reason" => reason || kind.tr("_", " "),
      "provenance" => { "source" => "stage_service", "ingested_at" => at },
      "payload" => {
        "activity_kind" => kind, "operation_id" => "operation:#{id}",
        "correlation_id" => correlation, "supersedes_event_id" => supersedes
      }
    }
  end

  def event(id, kind, at:, ingested_at: nil, source: nil, correlation: nil)
    {
      "event_id" => id, "event_type" => kind, "ts" => at,
      "occurred_at" => at, "ingested_at" => ingested_at || at,
      "stage" => "4-execute", "source" => source,
      "correlation_id" => correlation
    }
  end
end
