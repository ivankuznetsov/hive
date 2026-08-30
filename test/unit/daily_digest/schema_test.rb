require "test_helper"
require "json_schemer"
require "hive/daily_digest/calendar"
require "hive/daily_digest/collector"
require "hive/daily_digest/materiality"
require "hive/daily_digest/projector"
require "hive/daily_digest/record"

class DailyDigestSchemaTest < Minitest::Test
  NOW = Time.iso8601("2026-08-30T12:00:00Z")

  def test_record_schema_accepts_a_projected_store_record_and_is_closed
    interval = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                         .interval_for("2026-08-30", sequence: 1)
    fact = Hive::DailyDigest::Materiality.creation_fact(
      "creation_id" => "creation-1", "project_id" => "project-1",
      "project_name" => "demo", "task_id" => 42, "task_slug" => "daily-demo",
      "stage" => "1-inbox", "created_at" => "2026-08-30T10:00:00Z",
      "workflow" => "coding"
    )
    gap = Hive::DailyDigest::Materiality.build_gap(
      source: "github", scope: "demo", reason_code: "unavailable",
      reason: "GitHub unavailable", observed_at: NOW,
      project_id: "project-1", task_slug: "daily-demo"
    )
    attention = {
      "attention_id" => "attention:one", "kind" => "unanswered",
      "project_id" => "project-1", "project" => "demo", "task_id" => "42",
      "task_slug" => "daily-demo", "stage" => "2-brainstorm",
      "state" => "waiting_on_you", "since_at" => "2026-08-30T09:00:00Z",
      "waiting_age_seconds" => 10_800,
      "task_path" => "/tasks/demo/daily-demo#task-questions"
    }
    batch = Hive::DailyDigest::Collector::Result.new(
      projects: [ { "project_id" => "project-1", "name" => "demo" } ],
      facts: [ fact ], attention: [ attention ], gaps: [ gap ],
      frontiers: { "project-1" => { "source" => "task_journal", "fingerprints" => [] } },
      completeness: "partial", content: "non_empty"
    )
    projected = Hive::DailyDigest::Projector.new(clock: -> { NOW }).base(
      interval: interval, batch: batch, lifecycle: "closed"
    )
    record = Hive::DailyDigest::Record.prepare(projected)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest-record"))))

    assert_empty schema.validate(record).to_a
    refute schema.valid?(record.merge("question" => "secret"))
    %w[projects items attention gaps].each do |key|
      nested = record.merge(key => [ record.fetch(key).first.merge("unknown" => "secret") ])
      refute schema.valid?(nested), "#{key} entries must keep a closed schema"
    end
    fact_with_unknown_detail = record.fetch("items").first.merge(
      "details" => record.dig("items", 0, "details").merge("raw_payload" => "secret")
    )
    refute schema.valid?(record.merge("items" => [ fact_with_unknown_detail ])),
           "fact details must keep a closed schema"
  end
end
