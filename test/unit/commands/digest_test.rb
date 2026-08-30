require "test_helper"
require "json_schemer"
require "hive/commands/digest"

class DigestCommandTest < Minitest::Test
  def test_json_is_a_pure_schema_valid_view_with_canonical_web_url
    calls = []
    reader = Object.new
    record = digest_record
    reader.define_singleton_method(:read) do |**options|
      calls << options
      record
    end
    output = StringIO.new
    opened = []

    payload = Hive::Commands::Digest.new(
      date: "2026-08-30", project: "alpha team", json: true,
      reader: reader, web_config_loader: -> { { "origin" => "https://hive.example/" } },
      browser_opener: ->(url) { opened << url }, stdout: output
    ).call

    assert_equal [ { date: "2026-08-30", project: "alpha team" } ], calls
    assert_empty opened
    assert_equal payload, JSON.parse(output.string)
    assert_equal "hive-digest", payload.fetch("schema")
    assert_equal "record-1", payload.fetch("record_id")
    assert_equal "alpha team", payload.fetch("selected_project")
    assert_equal "https://hive.example/digests/2026-08-30?project=alpha+team",
                 payload.fetch("web_url")
    assert_empty digest_schema.validate(payload).to_a
  end

  def test_text_is_attention_first_and_sanitizes_renderer_active_fields
    output = StringIO.new
    unsafe = digest_record
    unsafe["attention"][0]["task_slug"] = "blocked\n\e]8;;https://evil.test\aescape"
    unsafe["items"][0]["summary"] = "advanced\e[2J\nnext"
    reader = Object.new
    reader.define_singleton_method(:read) { |**| unsafe }

    Hive::Commands::Digest.new(
      reader: reader, stdout: output,
      web_config_loader: -> { { "origin" => "http://127.0.0.1:4567" } }
    ).call

    rendered = output.string
    assert_operator rendered.index("Needs attention"), :<, rendered.index("Project activity")
    refute_includes rendered, "\e"
    refute_includes rendered, "\a"
    assert_includes rendered, "blocked??]8;;https://evil.test?escape"
    assert_includes rendered, "advanced?next"
  end

  def test_open_web_is_explicit_and_mutually_exclusive_with_json
    opened = []
    output = StringIO.new
    reader = Object.new
    record = digest_record
    record["selected_project"] = nil
    reader.define_singleton_method(:read) { |**| record }

    Hive::Commands::Digest.new(
      open_web: true, reader: reader, stdout: output,
      web_config_loader: -> { { "origin" => "https://hive.example" } },
      browser_opener: ->(url) { opened << url; true }
    ).call

    assert_equal [ "https://hive.example/digests/2026-08-30" ], opened
    assert_includes output.string, opened.first

    error = assert_raises(Hive::UsageError) do
      Hive::Commands::Digest.new(
        json: true, open_web: true, reader: reader,
        browser_opener: ->(_url) { flunk "browser must not open" },
        stdout: StringIO.new
      ).call
    end
    assert_match(/mutually exclusive/, error.message)
  end

  def test_missing_and_pruned_are_distinct_closed_shape_results
    reader = Object.new
    values = [
      {
        "reader_status" => "missing", "local_date" => "2026-08-29",
        "coverage_started_at" => "2026-08-30T00:00:00Z",
        "precoverage" => true, "stale" => false
      },
      {
        "reader_status" => "pruned", "lifecycle" => "pruned",
        "local_date" => "2026-08-30", "record_id" => "record-pruned",
        "pruned_at" => "2026-09-05T00:00:00Z", "stale" => false,
        "interval" => {
          "local_date" => "2026-08-30", "sequence" => 1,
          "time_zone" => "UTC", "starts_at" => "2026-08-30T00:00:00Z",
          "ends_at" => "2026-08-31T00:00:00Z", "boundary_kind" => "calendar_day"
        }
      }
    ]
    reader.define_singleton_method(:read) { |**| values.shift }
    command = -> {
      Hive::Commands::Digest.new(
        json: true, reader: reader, stdout: StringIO.new,
        web_config_loader: -> { { "origin" => "https://hive.example" } }
      ).call
    }

    missing = command.call
    pruned = command.call

    assert_equal "missing", missing.fetch("reader_status")
    assert_equal "missing", missing.fetch("lifecycle")
    assert_equal "unknown", missing.fetch("content")
    assert_equal true, missing.fetch("precoverage")
    assert_equal "pruned", pruned.fetch("reader_status")
    assert_equal "pruned", pruned.fetch("lifecycle")
    assert_equal "record-pruned", pruned.fetch("record_id")
    [ missing, pruned ].each { |payload| assert_empty digest_schema.validate(payload).to_a }
  end

  def self.digest_record
    {
      "reader_status" => "ok", "record_id" => "record-1",
      "local_date" => "2026-08-30", "sequence" => 1,
      "time_zone" => "Europe/London", "starts_at" => "2026-08-29T23:00:00Z",
      "ends_at" => "2026-08-30T23:00:00Z", "boundary_kind" => "calendar_day",
      "lifecycle" => "closed", "closed_at" => "2026-08-30T23:05:00Z",
      "completeness" => "complete", "effective_completeness" => "complete",
      "view_completeness" => "complete", "content" => "non_empty",
      "effective_content" => "non_empty", "last_materialized_at" => "2026-08-30T23:05:00Z",
      "stale" => false, "selected_project" => "alpha team",
      "previous_date" => "2026-08-29", "next_date" => nil,
      "projects" => [ { "project_id" => "alpha", "name" => "alpha team" } ],
      "attention" => [
        {
          "attention_id" => "attention-1", "kind" => "blocked",
          "project_id" => "alpha", "project" => "alpha team", "task_id" => 42,
          "task_slug" => "blocked-task", "stage" => "3-plan", "state" => "waiting",
          "waiting_since" => "2026-08-30T10:00:00Z", "waiting_age_seconds" => 3_600,
          "task_url" => "https://hive.example/projects/alpha/tasks/42#task-questions"
        }
      ],
      "items" => [
        {
          "fact_id" => "fact-1", "kind" => "stage_transition", "category" => "progress",
          "summary" => "Task stage changed", "project_id" => "alpha",
          "project" => "alpha team", "task_id" => 42, "task_slug" => "blocked-task",
          "stage" => "3-plan", "occurred_at" => "2026-08-30T09:00:00Z",
          "observed_at" => "2026-08-30T09:01:00Z", "source" => "task_journal",
          "details" => { "to_stage" => "3-plan" }
        }
      ],
      "gaps" => [], "effective_gaps" => [], "amendments" => []
    }
  end

  def digest_record
    JSON.parse(JSON.generate(self.class.digest_record))
  end

  def digest_schema
    @digest_schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest")))
    )
  end
end
