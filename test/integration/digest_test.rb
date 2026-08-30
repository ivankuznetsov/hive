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
      store = Hive::DailyDigest::Store.new
      stored = store.write_base(record)
      before = File.binread(store.base_path("2026-08-30"))

      json_out, json_err, json_status = run_hive(home, "digest", "--date", "2026-08-30", "--json")
      text_out, text_err, text_status = run_hive(home, "digest", "--date", "2026-08-30")

      assert json_status.success?, json_err
      assert text_status.success?, text_err
      payload = JSON.parse(json_out)
      assert_equal stored.fetch("record_id"), payload.fetch("record_id")
      assert_equal "https://hive.example/digests/2026-08-30", payload.fetch("web_url")
      assert_includes text_out, "Task stage changed"
      assert_empty digest_schema.validate(payload).to_a
      assert_equal before, File.binread(store.base_path("2026-08-30"))
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

  def record
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "interval_id" => "a" * 64,
      "local_date" => "2026-08-30", "sequence" => 1,
      "time_zone" => "Europe/London", "starts_at" => "2026-08-29T23:00:00Z",
      "ends_at" => "2026-08-30T23:00:00Z", "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day", "cutover" => nil,
      "lifecycle" => "closed", "closed_at" => "2026-08-30T23:01:00Z",
      "completeness" => "complete", "content" => "non_empty",
      "last_materialized_at" => "2026-08-30T23:01:00Z",
      "projects" => [ { "project_id" => "demo", "name" => "demo" } ],
      "items" => [
        {
          "fact_id" => "fact:stage", "kind" => "stage_transition",
          "project_id" => "demo", "project" => "demo", "task_slug" => "daily-task",
          "summary" => "Task stage changed", "occurred_at" => "2026-08-30T10:00:00Z",
          "observed_at" => "2026-08-30T10:00:01Z", "source" => "task_journal",
          "details" => {}
        }
      ],
      "attention" => [], "gaps" => [], "source_frontiers" => {}
    }
  end
end
