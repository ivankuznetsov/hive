require "test_helper"
require "json_schemer"
require "open3"
require "rbconfig"
require "hive/daily_digest/store"

class DailyDigestIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def test_cli_json_and_text_read_the_same_persisted_record_without_mutation
    with_tmp_global_config do |home|
      config_path = File.join(home, "config.yml")
      config = YAML.safe_load_file(config_path)
      config["web"] = { "origin" => "https://hive.example" }
      File.write(config_path, config.to_yaml)
      project_root = File.join(home, "projects", "demo")
      task_root = File.join(project_root, ".hive-state", "stages", "1-inbox", "daily-task")
      FileUtils.mkdir_p(task_root)
      File.write(File.join(project_root, ".hive-state", "config.yml"), {}.to_yaml)
      File.write(File.join(task_root, "idea.md"), "# Daily task\n")
      registered = Hive::Config.register_project(
        name: "demo", path: project_root, repository_identity: nil,
        now: Time.iso8601("2026-08-29T08:00:00Z")
      )
      store = Hive::DailyDigest::Store.new
      store.write_base(previous_record(registered))
      stored = store.write_base(record(registered))
      store.append_amendment("2026-08-30", amendment(registered))
      before = projection_snapshot(store.root)

      json_out, json_err, json_status = run_hive(home, "digest", "--date", "2026-08-30", "--json")
      text_out, text_err, text_status = run_hive(home, "digest", "--date", "2026-08-30")
      historical_out, historical_err, historical_status = run_hive(
        home, "digest", "--date", "2026-08-30", "--project", "removed-project", "--json"
      )

      assert json_status.success?, json_err
      assert text_status.success?, text_err
      assert historical_status.success?, historical_err
      payload = JSON.parse(json_out)
      historical = JSON.parse(historical_out)
      assert_equal stored.fetch("record_id"), payload.fetch("record_id")
      assert_equal stored.fetch("record_id"), historical.fetch("record_id")
      assert_equal stored.fetch("interval_id"), historical.fetch("interval_id")
      assert_equal "2026-08-29", payload.fetch("previous_date")
      assert_equal "https://hive.example/digests/2026-08-30", payload.fetch("web_url")
      assert_equal "https://hive.example/digests/2026-08-30?project=removed-project",
                   historical.fetch("web_url")
      active = payload.fetch("items").find { |item| item["fact_id"] == "fact:stage" }
      assert_equal "/tasks/demo/daily-task", active.fetch("task_url")
      assert_equal "https://github.com/acme/demo/pull/42", active.dig("pr", "url")
      historical_item = historical.fetch("items").first
      assert_equal "removed-project", historical_item.fetch("project")
      assert_equal true, historical_item.fetch("historical")
      refute historical_item.key?("task_url")
      assert_equal [ "gap:github:demo" ],
                   payload.dig("amendments", 0, "resolved_gap_ids")
      assert_includes text_out, "Task stage changed"
      assert_includes text_out, stored.fetch("record_id")
      assert_includes text_out, "/tasks/demo/daily-task"
      assert_includes text_out, "https://github.com/acme/demo/pull/42"
      assert_includes text_out, "advanced?next"
      refute_includes text_out, "\e"
      assert_empty digest_schema.validate(payload).to_a
      assert_empty digest_schema.validate(historical).to_a
      assert_equal before, projection_snapshot(store.root)
    end
  end

  def test_json_and_open_web_conflict_fails_before_browser_launch
    with_tmp_global_config do |home|
      marker = File.join(home, "browser-called")
      browser = File.join(home, "browser")
      File.write(browser, "#!/bin/sh\ntouch #{Shellwords.escape(marker)}\n")
      File.chmod(0o755, browser)

      out, _err, status = Open3.capture3(
        ruby_environment(home).merge("BROWSER" => browser),
        RbConfig.ruby, "-Ilib", HIVE_BIN,
        "digest", "--json", "--open-web", "--date", "2026-08-30"
      )

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "usage", payload.fetch("error_kind")
      refute File.exist?(marker)
      assert_empty digest_schema.validate(payload).to_a
    end
  end

  def test_public_json_distinguishes_empty_partial_stale_and_pruned_history
    with_tmp_global_config do |home|
      config_path = File.join(home, "config.yml")
      config = YAML.safe_load_file(config_path)
      config["web"] = { "origin" => "https://hive.example" }
      File.write(config_path, config.to_yaml)
      store = Hive::DailyDigest::Store.new
      store.write_base(state_record("2026-08-25", sequence: 1, identity: "c"))
      store.write_base(
        state_record(
          "2026-08-26", sequence: 2, identity: "d",
          completeness: "partial", content: "unknown", gaps: [ gap ]
        )
      )
      store.write_base(
        state_record(
          "2026-08-27", sequence: 3, identity: "e", lifecycle: "open",
          last_materialized_at: "2026-08-27T00:00:01Z"
        )
      )
      store.write_base(state_record("2026-08-28", sequence: 4, identity: "f"))
      store.prune(
        "2026-08-28", pruned_at: "2026-08-29T00:00:00Z", reason: "operator_confirmed"
      )

      states = %w[2026-08-25 2026-08-26 2026-08-27 2026-08-28].to_h do |date|
        out, err, status = run_hive(home, "digest", "--date", date, "--json")
        assert status.success?, err
        payload = JSON.parse(out)
        assert_empty digest_schema.validate(payload).to_a
        [ date, payload ]
      end

      assert_equal %w[closed complete empty],
                   states.fetch("2026-08-25").values_at("lifecycle", "completeness", "content")
      assert_equal %w[closed partial unknown],
                   states.fetch("2026-08-26").values_at("lifecycle", "completeness", "content")
      assert_equal %w[open partial unknown],
                   states.fetch("2026-08-27").values_at("lifecycle", "completeness", "content")
      assert_equal true, states.fetch("2026-08-27").fetch("stale")
      assert_equal %w[pruned unknown unknown],
                   states.fetch("2026-08-28").values_at("lifecycle", "completeness", "content")
    end
  end

  private

  def run_hive(home, *args)
    Open3.capture3(ruby_environment(home), RbConfig.ruby, "-Ilib", HIVE_BIN, *args)
  end

  def ruby_environment(home)
    {
      "HIVE_HOME" => home,
      "GEM_HOME" => Gem.dir,
      "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR)
    }
  end

  def digest_schema
    @digest_schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest")))
    )
  end

  def projection_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next unless File.file?(path)

      [ path.delete_prefix("#{root}/"), File.binread(path) ]
    end.to_h
  end

  def previous_record(project)
    record(project).merge(
      "interval_id" => "a" * 64, "local_date" => "2026-08-29", "sequence" => 1,
      "starts_at" => "2026-08-28T23:00:00Z", "ends_at" => "2026-08-29T23:00:00Z",
      "closed_at" => "2026-08-29T23:01:00Z",
      "last_materialized_at" => "2026-08-29T23:01:00Z",
      "completeness" => "complete", "content" => "empty",
      "items" => [], "attention" => [], "gaps" => [], "source_frontiers" => {}
    )
  end

  def state_record(date, sequence:, identity:, lifecycle: "closed", completeness: "complete",
                   content: "empty", gaps: [], last_materialized_at: nil)
    start = Time.iso8601("#{date}T00:00:00Z")
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => identity * 64, "local_date" => date, "sequence" => sequence,
      "time_zone" => "UTC", "starts_at" => start.iso8601,
      "ends_at" => (start + 86_400).iso8601, "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => lifecycle,
      "closed_at" => lifecycle == "closed" ? (start + 86_401).iso8601 : nil,
      "completeness" => completeness, "content" => content,
      "last_materialized_at" => last_materialized_at || (start + 86_401).iso8601,
      "projects" => [], "items" => [], "attention" => [], "gaps" => gaps,
      "source_frontiers" => {}
    }
  end

  def record(project)
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => "b" * 64,
      "local_date" => "2026-08-30", "sequence" => 2,
      "time_zone" => "Europe/London", "starts_at" => "2026-08-29T23:00:00Z",
      "ends_at" => "2026-08-30T23:00:00Z", "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => "closed", "closed_at" => "2026-08-30T23:01:00Z",
      "completeness" => "partial", "content" => "non_empty",
      "last_materialized_at" => "2026-08-30T23:01:00Z",
      "projects" => [
        project.slice("project_id", "registration_id", "name"),
        { "project_id" => "removed", "registration_id" => "old", "name" => "removed-project" }
      ],
      "items" => [
        {
          "fact_id" => "fact:stage", "kind" => "stage_transition",
          "project_id" => project.fetch("project_id"),
          "registration_id" => project.fetch("registration_id"),
          "project" => "demo", "task_slug" => "daily-task",
          "summary" => "Task stage changed", "occurred_at" => "2026-08-30T10:00:00Z",
          "observed_at" => "2026-08-30T10:00:01Z", "source" => "task_journal",
          "details" => {},
          "pr" => {
            "number" => 42, "url" => "https://github.com/acme/demo/pull/42",
            "state" => "open", "draft" => false, "head_revision" => "a" * 40,
            "checks" => "passing", "review" => "approved", "merged_at" => nil
          }
        },
        {
          "fact_id" => "fact:removed", "kind" => "task_created",
          "project_id" => "removed", "registration_id" => "old",
          "project" => "removed-project", "task_slug" => "historical-task",
          "summary" => "Task created", "occurred_at" => "2026-08-30T11:00:00Z",
          "observed_at" => "2026-08-30T11:00:01Z", "source" => "task_creation_receipt",
          "details" => {}
        }
      ],
      "attention" => [], "gaps" => [ gap ], "source_frontiers" => {}
    }
  end

  def gap
    {
      "gap_id" => "gap:github:demo", "source" => "github", "scope" => "demo",
      "reason_code" => "unavailable", "reason" => "GitHub unavailable",
      "observed_at" => "2026-08-30T22:00:00Z", "freshness_at" => nil,
      "project_id" => nil, "registration_id" => nil, "task_slug" => nil
    }
  end

  def amendment(project)
    {
      "amendment_id" => "amendment:late-recovery", "kind" => "gap_resolution",
      "source" => "github", "event_at" => "2026-08-30T20:00:00Z",
      "observed_at" => "2026-08-31T08:00:00Z", "amended_at" => "2026-08-31T08:00:01Z",
      "items" => [ {
        "fact_id" => "fact:late", "kind" => "merge_observed", "category" => "completion",
        "summary" => "advanced\e[2J\nnext", "project_id" => project.fetch("project_id"),
        "registration_id" => project.fetch("registration_id"), "project" => "demo",
        "task_slug" => "daily-task", "occurred_at" => "2026-08-30T20:00:00Z",
        "observed_at" => "2026-08-31T08:00:00Z", "source" => "task_journal",
        "details" => { "merge_state" => "merged" }
      } ],
      "attention" => [], "gaps" => [],
      "resolved_gap_ids" => [ gap.fetch("gap_id") ], "resolved_gaps" => [ gap ],
      "resolved_attention_ids" => [], "resolved_attention" => [], "source_frontiers" => {}
    }
  end
end
