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
end
