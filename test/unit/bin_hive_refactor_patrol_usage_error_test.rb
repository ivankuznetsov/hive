require "test_helper"
require "json_schemer"
require "open3"
require "rbconfig"

class BinHiveRefactorPatrolUsageErrorTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__).freeze
  BIN = File.join(ROOT, "bin", "hive").freeze

  def test_help_documents_changed_since_as_a_scoped_filter
    Dir.mktmpdir("hive-bin-help") do |home|
      stdout, stderr, status = Open3.capture3(
        { "HOME" => home, "HIVE_HOME" => home },
        RbConfig.ruby, BIN, "refactor-patrol", "--help",
        chdir: ROOT
      )

      assert status.success?, stderr
      assert_includes stdout, "--changed-since is only a filter paired with"
      assert_includes stdout, "git ref filter paired with --feature/--entrypoint/--path"
      refute_includes stdout, "changed features are boosted"
    end
  end

  def test_refactor_patrol_usage_error_is_schema_valid_v4
    payload = run_usage_error("refactor-patrol", "demo", "extra", "--json")

    assert_equal 4, payload.fetch("schema_version")
    assert schema.valid?(payload), validation_errors(payload)
    refute payload.key?("job_id")
    refute payload.key?("source_pr")
    refute payload.key?("complete")
  end

  def test_pr_job_manifest_and_actions_usage_errors_are_schema_valid_v4
    selectors = [
      [ "--pr", "7" ],
      [ "--job-manifest", "/tmp/job.json" ],
      [ "--actions" ]
    ]

    selectors.each do |selector|
      payload = run_usage_error(
        "refactor-patrol", "demo", "extra", *selector, "--json"
      )

      assert_equal 4, payload.fetch("schema_version"), selector.inspect
      assert schema.valid?(payload), "#{selector.inspect}: #{validation_errors(payload)}"
      refute payload.key?("job_id")
      refute payload.key?("source_pr")
      refute payload.key?("complete")
    end
  end

  def test_last_negative_actions_form_keeps_current_usage_error_v4
    selectors = [
      [ "--actions", "--no-actions" ],
      [ "--actions", "--skip-actions" ],
      [ "--actions=true", "--actions=false" ]
    ]

    selectors.each do |selector|
      payload = run_usage_error(
        "refactor-patrol", "demo", "extra", *selector, "--json"
      )

      assert_equal 4, payload.fetch("schema_version"), selector.inspect
      assert schema.valid?(payload), "#{selector.inspect}: #{validation_errors(payload)}"
    end
  end

  def test_job_query_usage_errors_use_the_read_only_jobs_contract
    {
      [ "--list" ] => "list",
      [ "--list=true" ] => "list",
      [ "--no-list", "--list" ] => "list",
      [ "--list", "--limit", "25" ] => "list",
      [ "--show", "job-7" ] => "show",
      [ "--show", "job-7", "--full" ] => "show",
      [ "--show", "job-7", "--list", "--no-list" ] => "show",
      [ "--show", "job-7", "--list" ] => "list"
    }.each do |selector, action|
      payload = run_usage_error(
        "refactor-patrol", "demo", "extra", *selector, "--json"
      )

      assert_equal "hive-refactor-patrol-jobs", payload.fetch("schema")
      assert_equal 2, payload.fetch("schema_version")
      assert_equal action, payload.fetch("action"), selector.inspect
      assert job_query_schema.valid?(payload),
             job_query_schema.validate(payload).map { |error| error.fetch("error") }.inspect
    end
  end

  def test_last_negative_list_form_keeps_current_usage_error_v4
    [ [ "--list", "--no-list" ], [ "--list", "--skip-list" ],
      [ "--list=true", "--list=false" ] ].each do |selector|
      payload = run_usage_error(
        "refactor-patrol", "demo", "extra", *selector, "--json"
      )

      assert_equal "hive-refactor-patrol", payload.fetch("schema"), selector.inspect
      assert_equal 4, payload.fetch("schema_version"), selector.inspect
      assert schema.valid?(payload), "#{selector.inspect}: #{validation_errors(payload)}"
    end
  end


  def test_malformed_query_limit_uses_the_jobs_usage_contract
    payload = run_usage_error(
      "refactor-patrol", "demo", "--list", "--limit", "many", "--json"
    )

    assert_equal "hive-refactor-patrol-jobs", payload.fetch("schema")
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal "list", payload.fetch("action")
    assert job_query_schema.valid?(payload),
           job_query_schema.validate(payload).map { |error| error.fetch("error") }.inspect
  end

  def test_selectorless_query_modifiers_use_the_jobs_usage_contract
    [ [ "--limit", "1" ], [ "--cursor", "opaque" ], [ "--full" ] ].each do |modifier|
      payload = run_usage_error(
        "refactor-patrol", "demo", "extra", *modifier, "--json"
      )

      assert_equal "hive-refactor-patrol-jobs", payload.fetch("schema"), modifier.inspect
      assert_equal "usage", payload.fetch("error_kind"), modifier.inspect
      assert_nil payload.fetch("action"), modifier.inspect
      assert job_query_schema.valid?(payload),
             job_query_schema.validate(payload).map { |error| error.fetch("error") }.inspect
    end
  end

  private

  def run_usage_error(*argv)
    Dir.mktmpdir("hive-bin-usage") do |home|
      stdout, stderr, status = Open3.capture3(
        { "HOME" => home, "HIVE_HOME" => home },
        RbConfig.ruby, BIN, *argv,
        chdir: ROOT
      )
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus, stderr
      assert_match(/Usage:|Expected numeric value/, stderr)
      return JSON.parse(stdout)
    end
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol")))
    )
  end

  def validation_errors(payload)
    schema.validate(payload).map { |error| error.fetch("error") }.inspect
  end

  def job_query_schema
    @job_query_schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol-jobs")))
    )
  end
end
