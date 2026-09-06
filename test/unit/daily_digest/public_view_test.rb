require "test_helper"
require "json"
require "hive/daily_digest/public_view"

class DailyDigestPublicViewTest < Minitest::Test
  def test_sanitize_nested_applies_closed_allowlists_to_the_whole_record
    fact = {
      fact_id: "fact-1", kind: "stage_transition", project: "demo",
      details: { transition: "completed", secret: "question text" },
      pr: { number: 42, url: "https://github.com/acme/demo/pull/42", title: "secret title" },
      secret: "source payload"
    }
    gap = {
      gap_id: "gap-1", source: "github", scope: "demo", reason_code: "offline",
      reason: "bounded reason", secret: "credential"
    }
    record = {
      schema: "hive-digest", internal: "store-only",
      projects: [ { project_id: "project-1", name: "demo", secret: "path" } ],
      items: [ fact ],
      attention: [ { attention_id: "attention-1", kind: "blocked", secret: "prompt" } ],
      gaps: [ gap ], effective_gaps: [ gap ],
      amendments: [ {
        amendment_id: "amendment-1", kind: "late_observation", source: "task_journal",
        items: [ fact ], attention: [], gaps: [ gap ],
        resolved_gap_ids: [ :"gap-1" ], resolved_gaps: [ gap ], secret: "raw amendment"
      } ]
    }

    sanitized = Hive::DailyDigest::PublicView.sanitize_nested(record)

    assert_equal "demo", sanitized.dig("projects", 0, "name")
    assert_equal "completed", sanitized.dig("items", 0, "details", "transition")
    assert_equal 42, sanitized.dig("items", 0, "pr", "number")
    assert_equal [ "gap-1" ], sanitized.dig("amendments", 0, "resolved_gap_ids")
    refute_includes JSON.generate(sanitized), "secret"
    refute sanitized.dig("items", 0, "pr").key?("title")
  end

  def test_shared_ordering_follows_project_registration_then_time_and_identity
    record = {
      "projects" => [
        { "project_id" => "two", "name" => "Zulu" },
        { "project_id" => "one", "name" => "Alpha" }
      ],
      "items" => [
        { "fact_id" => "fact:b", "project_id" => "one", "occurred_at" => "2026-08-30T09:00:00Z" },
        { "fact_id" => "fact:z", "project_id" => "two", "occurred_at" => "2026-08-30T10:00:00Z" },
        { "fact_id" => "fact:a", "project_id" => "two", "occurred_at" => "2026-08-30T10:00:00Z" }
      ]
    }

    assert_equal %w[fact:a fact:z fact:b],
                 Hive::DailyDigest::PublicView.ordered_items(record).map { |row| row.fetch("fact_id") }
    assert_equal %w[two one],
                 Hive::DailyDigest::PublicView.grouped_items(record).map(&:first)
  end

  def test_outcome_labels_expose_bounded_transition_and_pr_results
    transition = { "kind" => "stage_transition", "details" => { "to_stage" => "6-review" } }
    check = { "kind" => "check_observed", "details" => { "check_state" => "passing" } }

    assert_equal "to 6-review", Hive::DailyDigest::PublicView.outcome_label(transition)
    assert_equal "passing", Hive::DailyDigest::PublicView.outcome_label(check)
  end
end
