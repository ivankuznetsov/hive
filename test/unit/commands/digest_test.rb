require "test_helper"
require "json_schemer"
require "hive/commands/digest"
require "hive/daily_digest/project_source"

class DigestCommandTest < Minitest::Test
  include HiveTestHelper

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

  def test_json_recursively_allowlists_every_persisted_collection
    record = digest_record
    record["projects"][0]["secret"] = "PROJECT SECRET"
    record["attention"][0]["question"] = "PRIVATE QUESTION"
    record["attention"][0]["binding"] = "SECRET BINDING"
    record["items"][0]["raw_payload"] = "ITEM SECRET"
    record["items"][0]["details"]["prompt"] = "DETAIL SECRET"
    record["items"][0]["pr"] = {
      "number" => 42, "url" => "https://github.com/acme/demo/pull/42",
      "token" => "PR SECRET"
    }
    record["effective_gaps"] = [ {
      "gap_id" => "gap:one", "source" => "github", "scope" => "alpha",
      "reason_code" => "offline", "reason" => "offline",
      "observed_at" => "2026-08-30T09:00:00Z", "freshness_at" => nil,
      "payload" => "GAP SECRET"
    } ]
    record["amendments"] = [ {
      "amendment_id" => "amendment:one", "kind" => "gap_resolution",
      "source" => "github", "event_at" => nil,
      "observed_at" => "2026-08-31T09:00:00Z",
      "amended_at" => "2026-08-31T09:00:01Z", "internal" => "AMENDMENT SECRET",
      "items" => [ record["items"][0] ], "attention" => [ record["attention"][0] ],
      "gaps" => [], "resolved_gap_ids" => [ "gap:one" ],
      "resolved_gaps" => [ record["effective_gaps"][0] ]
    } ]
    reader = Object.new
    reader.define_singleton_method(:read) { |**| record }
    output = StringIO.new

    payload = Hive::Commands::Digest.new(
      json: true, reader: reader, stdout: output,
      web_config_loader: -> { { "origin" => "https://hive.example" } }
    ).call

    serialized = JSON.generate(payload)
    %w[PROJECT\ SECRET PRIVATE\ QUESTION SECRET\ BINDING ITEM\ SECRET DETAIL\ SECRET
       PR\ SECRET GAP\ SECRET AMENDMENT\ SECRET].each do |secret|
      refute_includes serialized, secret.tr("\\", "")
    end
    assert_equal "https://github.com/acme/demo/pull/42", payload.dig("items", 0, "pr", "url")
    assert_equal [ "gap:one" ], payload.dig("amendments", 0, "resolved_gap_ids")
    assert_empty digest_schema.validate(payload).to_a
  end

  def test_real_project_source_pr_shape_reaches_the_public_task_and_pr_links
    with_tmp_dir do |project_root|
      task = File.join(project_root, ".hive-state", "stages", "5-open-pr", "pr-task")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "pr.md"), <<~YAML)
        ---
        pr_url: https://github.com/acme/demo/pull/42
        pr_number: 42
        head_oid: #{"a" * 40}
        ---
      YAML
      event = {
        "schema" => "hive-task-journal", "schema_version" => 1,
        "event_id" => "event-pr", "event_type" => "activity_recorded",
        "occurred_at" => "2026-08-30T10:00:00Z",
        "observed_at" => "2026-08-30T10:00:01Z", "stage" => "5-open-pr",
        "task" => { "id" => "42", "slug" => "pr-task" },
        "provenance" => { "source" => "task_journal" },
        "payload" => {
          "activity_kind" => "pr_observed", "operation_id" => "open-pr",
          "pr_state" => "open"
        }
      }
      File.write(File.join(task, "task-journal.jsonl"), "#{JSON.generate(event)}\n")
      source = Hive::DailyDigest::ProjectSource.new(
        project: {
          "project_id" => "project-1", "registration_id" => "registration-1",
          "name" => "demo", "path" => project_root,
          "hive_state_path" => File.join(project_root, ".hive-state")
        },
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
        known_stage_dirs: %w[5-open-pr]
      ).collect
      record = digest_record.merge(
        "projects" => [ { "project_id" => "project-1", "name" => "demo" } ],
        "items" => source.facts, "attention" => [], "effective_gaps" => source.gaps
      )
      reader = Object.new
      reader.define_singleton_method(:read) { |**| record }

      payload = Hive::Commands::Digest.new(
        json: true, reader: reader, stdout: StringIO.new,
        task_links: Hive::DailyDigest::TaskLinks.new(
          current_projects: [ {
            "project_id" => "project-1", "registration_id" => "registration-1",
            "name" => "demo", "path" => project_root
          } ],
          resolver: ->(_project, row) { { project: "demo", slug: row.fetch("task_slug") } }
        ),
        web_config_loader: -> { { "origin" => "https://hive.example" } }
      ).call

      assert_equal "/tasks/demo/pr-task", payload.dig("items", 0, "task_url")
      assert_equal "https://github.com/acme/demo/pull/42", payload.dig("items", 0, "pr", "url")
      assert_empty digest_schema.validate(payload).to_a
    end
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

  def test_text_distinguishes_missing_pruned_empty_unknown_gaps_and_amendments
    origin = -> { { "origin" => "https://hive.example" } }
    outputs = []
    views = [
      { "reader_status" => "missing", "precoverage" => true },
      {
        "reader_status" => "pruned", "lifecycle" => "pruned",
        "local_date" => "2026-08-28", "stale" => false
      },
      digest_record.merge(
        "content" => "empty", "effective_content" => "empty",
        "items" => [], "attention" => []
      ),
      digest_record.merge(
        "content" => "unknown", "effective_content" => "unknown",
        "items" => [ digest_record.fetch("items").first.merge("occurred_at" => "unknown") ],
        "gaps" => [
          { "source" => "github", "scope" => "alpha", "reason" => "offline" }
        ],
        "effective_gaps" => [
          { "source" => "github", "scope" => "alpha", "reason" => "offline" }
        ],
        "amendments" => [
          {
            "amended_at" => "2026-08-31T08:00:00Z", "kind" => "gap_resolution",
            "items" => [], "resolved_gap_ids" => [ "gap-1" ],
            "resolved_gaps" => [ {
              "gap_id" => "gap-1", "source" => "github", "scope" => "alpha",
              "reason" => "offline", "observed_at" => "2026-08-30T09:00:00Z",
              "freshness_at" => nil
            } ]
          }
        ]
      ),
      digest_record.merge(
        "content" => "unknown", "effective_content" => "unknown",
        "items" => [], "attention" => []
      )
    ]
    reader = Object.new
    reader.define_singleton_method(:read) { |**| views.shift }

    [ nil, "2026-08-28", nil, nil, nil ].each do |date|
      output = StringIO.new
      Hive::Commands::Digest.new(
        date: date, reader: reader, stdout: output, web_config_loader: origin
      ).call
      outputs << output.string
    end

    assert_includes outputs[0], "before digest coverage began"
    assert_includes outputs[0], "Digest today is missing"
    assert_includes outputs[1], "was pruned"
    assert_includes outputs[2], "No material activity"
    assert_includes outputs[3], "Source gaps (1)"
    assert_includes outputs[3], "Late amendments (1)"
    assert_includes outputs[3], "recovered: github · alpha"
    assert_includes outputs[3], "unknown Task stage changed"
    assert_includes outputs[4], "source gaps prevent an empty-day claim"
  end

  def test_requested_date_fallback_and_renderer_helpers_cover_bounded_edges
    reader = Object.new
    reader.define_singleton_method(:read) { |**| { "reader_status" => "missing", "precoverage" => false } }
    origin = -> { { "origin" => "https://hive.example" } }

    valid = Hive::Commands::Digest.new(
      date: "2026-08-30", reader: reader, web_config_loader: origin, stdout: StringIO.new
    ).call
    invalid = Hive::Commands::Digest.new(
      date: "not-a-date", reader: reader, web_config_loader: origin, stdout: StringIO.new
    ).call
    assert_equal "2026-08-30", valid.fetch("local_date")
    assert_equal "not-a-date", invalid.fetch("local_date")

    command = Hive::Commands::Digest.new
    assert_equal "1m", command.send(:format_age, 60)
    assert_equal "59s", command.send(:format_age, 59)
    assert_equal "age unknown", command.send(:format_age, "bad")
    assert_equal "", command.send(:date_flag, nil)

    amendments = StringIO.new
    command = Hive::Commands::Digest.new(stdout: amendments)
    command.send(:render_amendments, [ {
      "amended_at" => "2026-08-31T08:00:00Z", "kind" => "late_observation",
      "items" => [ { "summary" => "Late completion", "project" => "demo", "task_slug" => "task" } ],
      "resolved_gap_ids" => [ "gap-1" ], "resolved_gaps" => []
    } ])
    assert_includes amendments.string, "late: Late completion · demo:task"
    assert_includes amendments.string, "recovered gap: gap-1"
  end

  def test_invalid_web_origins_and_unexpected_errors_emit_typed_json
    reader = Object.new
    value = digest_record
    reader.define_singleton_method(:read) { |**| value }
    [ "mailto:operator@example.test", "%" ].each do |origin|
      output = StringIO.new
      assert_raises(Hive::ConfigError) do
        Hive::Commands::Digest.new(
          json: true, reader: reader, stdout: output,
          web_config_loader: -> { { "origin" => origin } }
        ).call
      end
      assert_equal "config", JSON.parse(output.string).fetch("error_kind")
    end

    output = StringIO.new
    exploding = Object.new
    exploding.define_singleton_method(:read) { |**| raise "boom" }
    error = assert_raises(Hive::InternalError) do
      Hive::Commands::Digest.new(
        json: true, reader: exploding, stdout: output,
        web_config_loader: -> { { "origin" => "https://hive.example" } }
      ).call
    end
    assert_match(/RuntimeError: boom/, error.message)
    assert_equal "internal", JSON.parse(output.string).fetch("error_kind")
  end

  def test_default_browser_opener_and_epipe_are_bounded
    command = Hive::Commands::Digest.new
    calls = []
    command.define_singleton_method(:system) do |*args, **options|
      calls << [ args, options ]
      true
    end
    with_env("BROWSER" => nil) do
      assert_equal true, command.send(:open_browser, "https://hive.example/digests/today")
    end
    assert_equal "xdg-open", calls.first.first.first

    broken_output = Object.new
    broken_output.define_singleton_method(:puts) { |_value| raise Errno::EPIPE }
    broken = Hive::Commands::Digest.new(stdout: broken_output)
    broken.send(:emit_json, { "ok" => true })
    assert_equal true, broken.instance_variable_get(:@emitted)
  end

  def test_error_kinds_cover_every_typed_reader_failure
    command = Hive::Commands::Digest.new
    cases = {
      Hive::UsageError.new("usage") => "usage",
      Hive::ConfigError.new("config") => "config",
      Hive::DailyDigest::Reader::UnknownProject.new("project") => "unknown_project",
      Hive::DailyDigest::InvalidRecord.new("date") => "invalid_date",
      Hive::Commands::Digest::BrowserOpenFailed.new("browser") => "browser_unavailable",
      Hive::InternalError.new("internal") => "internal",
      Hive::DailyDigest::Error.new("digest") => "digest_error"
    }
    cases.each { |error, kind| assert_equal kind, command.send(:error_kind, error) }
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
