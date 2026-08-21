require "test_helper"
require "json"
require "open3"
require "rake"
require "yaml"
require_relative "../support/coverage"

class CiTestPartitionTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  UPLOAD_ARTIFACT_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
  DOWNLOAD_ARTIFACT_ACTION = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
  RAKEFILE_CONSTANTS = %i[
    HIVE_CI_GATE_TESTS
    HIVE_CI_GATE_TEST_OPTIONS
    HIVE_DEFAULT_TEST_FILES
    HIVE_COVERAGE_SHARD_COUNT
    HIVE_COVERAGE_SHARDS
    HIVE_HOSTILE_TEST_FILES
  ].freeze

  def test_default_suite_excludes_the_expensive_ci_gates
    with_loaded_rakefile do
      gate_tests = Object.const_get(:HIVE_CI_GATE_TESTS)
      gate_files = gate_tests.values
      default_files = Object.const_get(:HIVE_DEFAULT_TEST_FILES).to_a

      assert_equal({
        "test:packaged_web_bootstrap" => "test/integration/web_packaged_bootstrap_test.rb",
        "test:tui_reactivity_perf" => "test/integration/tui_reactivity_perf_test.rb",
        "test:setup_agents_integration" => "test/integration/setup_agents_test.rb",
        "test:babysitter_dry_run_security_matrix" =>
          "test/unit/babysitter/dry_run_security_matrix_test.rb"
      }, gate_tests)
      gate_files.each { |file| assert_path_exists File.join(ROOT, file) }
      assert_empty default_files & gate_files
      assert_equal gate_tests.keys.sort, Rake::Task.tasks.filter_map { |task|
        task.name if task.name.start_with?("test:") && gate_tests.key?(task.name)
      }.sort

      assert_equal({
        "test:babysitter_dry_run_security_matrix" =>
          "--include=test_stubs_skip_unknown_and_mutating_commands_but_allow_read_only_commands"
      }, Object.const_get(:HIVE_CI_GATE_TEST_OPTIONS))
      assert gate_tests.keys.all? { |name|
        Rake::Task[name].prerequisites == [ "test:require_nonempty_ci_gate" ]
      }
    end
  end

  def test_coverage_shards_are_complete_disjoint_and_split_the_measured_hot_partition
    with_loaded_rakefile do
      files = Object.const_get(:HIVE_DEFAULT_TEST_FILES)
      shard_count = Object.const_get(:HIVE_COVERAGE_SHARD_COUNT)
      shards = Object.const_get(:HIVE_COVERAGE_SHARDS)

      assert_equal 6, shard_count
      assert_equal shard_count, shards.length
      assert_equal files.sort, shards.flatten.sort
      assert_equal files.length, shards.flatten.uniq.length
      refute shards.any?(&:empty?)
      assert shards.all?(&:frozen?)
      assert shards.frozen?

      base_shards = size_balanced_shards(files, 4)
      assert_equal base_shards[0].sort, shards[0].sort
      assert_equal base_shards[1].sort, shards[1].sort
      assert_equal base_shards[2].sort, (shards[2] + shards[3]).sort
      assert_equal base_shards[3].sort, (shards[4] + shards[5]).sort

      [ shards[2, 2], shards[4, 2] ].each do |pair|
        byte_counts = pair.map { |shard| shard.sum { |path| File.size(File.join(ROOT, path)) } }
        assert_operator byte_counts.max - byte_counts.min, :<, 10_000,
                        "split hot coverage shards should remain source-byte balanced: #{byte_counts.inspect}"
      end
    end
  end

  def test_ci_runs_each_expensive_test_as_a_named_merge_gate
    with_loaded_rakefile do
      workflow = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"), aliases: true)
      gate_job = workflow.fetch("jobs").fetch("expensive-test-gates")
      matrix = gate_job.fetch("strategy").fetch("matrix").fetch("include")

      assert_equal [
        {
          "name" => "packaged Hive web bootstrap",
          "task" => "test:packaged_web_bootstrap"
        },
        {
          "name" => "TUI reactivity performance",
          "task" => "test:tui_reactivity_perf"
        },
        {
          "name" => "multi-agent setup integration",
          "task" => "test:setup_agents_integration"
        },
        {
          "name" => "babysitter dry-run security matrix",
          "task" => "test:babysitter_dry_run_security_matrix"
        }
      ], matrix
      assert_equal "${{ matrix.name }}", gate_job.fetch("name")
      assert_equal Object.const_get(:HIVE_CI_GATE_TESTS).keys, matrix.map { |entry| entry.fetch("task") }

      run_step = gate_job.fetch("steps").find { |step| step["name"] == "Run merge gate" }
      assert_equal 'bundle exec rake "$HIVE_CI_GATE_TASK"', run_step.fetch("run")
      assert_equal "${{ matrix.task }}", run_step.fetch("env").fetch("HIVE_CI_GATE_TASK")

      coverage_shards = workflow.fetch("jobs").fetch("coverage-shards")
      assert_equal "coverage shard ${{ matrix.label }}/6", coverage_shards.fetch("name")
      assert_equal [
        { "shard" => 0, "label" => 1 },
        { "shard" => 1, "label" => 2 },
        { "shard" => 2, "label" => 3 },
        { "shard" => 3, "label" => 4 },
        { "shard" => 4, "label" => 5 },
        { "shard" => 5, "label" => 6 }
      ], coverage_shards.dig("strategy", "matrix", "include")
      collect = coverage_shards.fetch("steps").find { |step| step["name"] == "Collect coverage shard" }
      assert_equal "bundle exec rake coverage:collect", collect.fetch("run")
      assert_equal "${{ matrix.shard }}", collect.fetch("env").fetch("HIVE_COVERAGE_SHARD_INDEX")
      assert_equal "6", collect.fetch("env").fetch("HIVE_COVERAGE_SHARD_COUNT")
      assert_equal "shard-${{ matrix.shard }}", collect.fetch("env").fetch("HIVE_COVERAGE_RUN_ID")
      assert_equal "${{ github.sha }}", collect.fetch("env").fetch("HIVE_COVERAGE_REVISION")
      assert_equal "${{ github.run_id }}",
                   collect.fetch("env").fetch("HIVE_COVERAGE_WORKFLOW_RUN_ID")

      upload = coverage_shards.fetch("steps").find { |step| step["name"] == "Retain raw coverage results" }
      assert_equal UPLOAD_ARTIFACT_ACTION, upload.fetch("uses")
      assert_equal "always()", upload.fetch("if")
      assert_equal "coverage-shard-${{ matrix.shard }}", upload.dig("with", "name")
      assert_equal "coverage/.resultset/shard-${{ matrix.shard }}", upload.dig("with", "path")
      assert_equal true, upload.dig("with", "include-hidden-files")
      assert_equal "error", upload.dig("with", "if-no-files-found")
      assert_equal true, upload.dig("with", "overwrite")

      coverage_gate = workflow.fetch("jobs").fetch("test")
      assert_equal "coverage (Ruby 3.4)", coverage_gate.fetch("name")
      assert_equal "${{ always() }}", coverage_gate.fetch("if")
      assert_equal "coverage-shards", coverage_gate.fetch("needs")
      shard_verdict = coverage_gate.fetch("steps").find { |step| step["name"] == "Require every coverage collector" }
      assert_equal "bash", shard_verdict.fetch("shell")
      assert_equal "${{ needs.coverage-shards.result }}",
                   shard_verdict.dig("env", "HIVE_COVERAGE_SHARDS_RESULT")
      assert_equal 'test "$HIVE_COVERAGE_SHARDS_RESULT" = "success"', shard_verdict.fetch("run")
      coverage_notice = coverage_gate.fetch("steps").find { |step| step["name"] == "Aggregation-only notice (no tests run in this job)" }
      assert coverage_notice, "coverage merge job must self-describe as an aggregator"
      assert_includes coverage_notice.fetch("run"), "GITHUB_STEP_SUMMARY"
      download = coverage_gate.fetch("steps").find { |step| step["name"] == "Download coverage shards" }
      assert_equal DOWNLOAD_ARTIFACT_ACTION, download.fetch("uses")
      assert_equal "coverage-shard-*", download.dig("with", "pattern")
      assert_equal "coverage/.resultset/merged", download.dig("with", "path")
      refute download.fetch("with").key?("merge-multiple")
      merge = coverage_gate.fetch("steps").find { |step| step["name"] == "Merge shards and enforce exact coverage" }
      assert_equal "bundle exec rake coverage:report", merge.fetch("run")
      assert_equal "100", merge.fetch("env").fetch("HIVE_COVERAGE_MIN_LINE")
      assert_equal "merged", merge.fetch("env").fetch("HIVE_COVERAGE_RUN_ID")
      assert_equal "6", merge.fetch("env").fetch("HIVE_COVERAGE_EXPECTED_SHARDS")
      assert_equal "${{ github.sha }}", merge.fetch("env").fetch("HIVE_COVERAGE_REVISION")
      assert_equal "${{ github.run_id }}",
                   merge.fetch("env").fetch("HIVE_COVERAGE_WORKFLOW_RUN_ID")

      required_gate = workflow.fetch("jobs").fetch("required-test-gate")
      assert_equal "rake test (Ruby 3.4)", required_gate.fetch("name")
      assert_equal "${{ always() }}", required_gate.fetch("if")
      assert_equal %w[test expensive-test-gates e2e], required_gate.fetch("needs")

      required_step = required_gate.fetch("steps").find { |step| step["name"] == "Require coverage, functional e2e, and expensive proof gates" }
      assert_equal "${{ needs.test.result }}",
                   required_step.fetch("env").fetch("HIVE_COVERAGE_RESULT")
      assert_equal "${{ needs.expensive-test-gates.result }}",
                   required_step.fetch("env").fetch("HIVE_EXPENSIVE_GATES_RESULT")
      assert_equal "${{ needs.e2e.result }}",
                   required_step.fetch("env").fetch("HIVE_E2E_RESULT")
      assert_equal "bash", required_step.fetch("shell")
      assert_equal <<~SHELL, required_step.fetch("run")
        test "$HIVE_COVERAGE_RESULT" = "success"
        test "$HIVE_EXPENSIVE_GATES_RESULT" = "success"
        test "$HIVE_E2E_RESULT" = "success"
      SHELL
    end
  end

  def test_workflow_creator_hostile_campaign_is_opt_in
    with_loaded_rakefile do
      hostile_files = Object.const_get(:HIVE_HOSTILE_TEST_FILES)
      default_files = Object.const_get(:HIVE_DEFAULT_TEST_FILES)
      workflow = File.read(File.join(ROOT, ".github", "workflows", "ci.yml"))

      assert_equal %w[
        test/unit/packaging/workflow_creator_values_test.rb
      ], hostile_files.sort
      assert hostile_files.all? { |file| default_files.include?(file) },
             "core Workflow Creator coverage must remain in the default suite"
      assert_equal [ "test:enable_hostile" ], Rake::Task["test:hostile"].prerequisites
      refute_includes workflow, "test:hostile"
      refute_includes workflow, "HIVE_HOSTILE_TESTS"
    end
  end

  def test_brakeman_reads_the_web_gemfile_while_scanning_the_repository_root
    workflow = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"), aliases: true)
    brakeman = workflow.fetch("jobs").fetch("brakeman")
    command = brakeman.fetch("steps").filter_map { |step| step["run"] }.fetch(0)

    assert_equal(
      "bundle exec brakeman --gemfile web/Gemfile --force --no-pager --quiet --format github " \
        "--ignore-config config/brakeman.ignore",
      command
    )
    refute_includes command, "--path web"
  end

  def test_ci_runs_independent_web_suites_in_parallel_behind_the_existing_gate
    workflow = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"), aliases: true)
    jobs = workflow.fetch("jobs")
    web_tests = jobs.fetch("web-tests")
    matrix = web_tests.dig("strategy", "matrix", "include")

    assert_equal [
      { "name" => "Hive web integration tests", "suite" => "integration" },
      { "name" => "Hive web system tests", "suite" => "system" },
      { "name" => "Hive web golden-path E2E", "suite" => "golden" }
    ], matrix
    assert_equal "${{ matrix.name }}", web_tests.fetch("name")
    assert_equal false, web_tests.dig("strategy", "fail-fast")

    steps = web_tests.fetch("steps")
    playwright = steps.find do |step|
      step["name"] == "Install Playwright chromium for Capybara system tests"
    end
    integration = steps.find { |step| step["name"] == "Rails integration tests" }
    system = steps.find { |step| step["name"] == "Rails system tests (Capybara + Playwright)" }
    golden = steps.find do |step|
      step["name"] == "Hive web golden-path E2E (claim → idea → Q&A → daemon → PR gate)"
    end
    golden_bundle = steps.find do |step|
      step["name"] == "Install the gem bundle (the golden-path E2E spawns a real daemon)"
    end
    lint = steps.find { |step| step["name"] == "rubocop (web)" }

    assert_equal "${{ matrix.suite != 'integration' }}", playwright.fetch("if")
    assert_equal "${{ matrix.suite == 'integration' }}", integration.fetch("if")
    assert_equal "bin/rails test", integration.fetch("run")
    assert_equal "${{ matrix.suite == 'system' }}", system.fetch("if")
    assert_equal "bin/rails test:system", system.fetch("run")
    assert_equal "${{ matrix.suite == 'golden' }}", golden.fetch("if")
    assert_equal "bin/rails test test/e2e/golden_path_e2e.rb", golden.fetch("run")
    assert_equal "${{ github.workspace }}/vendor/root-bundle",
                 golden.dig("env", "GOLDEN_E2E_BUNDLE_PATH")
    assert_equal "${{ matrix.suite == 'golden' }}", golden_bundle.fetch("if")
    assert_equal ".", golden_bundle.fetch("working-directory")
    assert_equal "bundle install --jobs 4", golden_bundle.fetch("run")
    assert_equal "${{ github.workspace }}/Gemfile", golden_bundle.dig("env", "BUNDLE_GEMFILE")
    assert_equal "${{ github.workspace }}/vendor/root-bundle",
                 golden_bundle.dig("env", "BUNDLE_PATH")
    assert_equal "${{ matrix.suite == 'integration' }}", lint.fetch("if")
    assert_equal "bin/rubocop --format github", lint.fetch("run")

    web_gate = jobs.fetch("web")
    assert_equal "Hive web (Rails tests + system)", web_gate.fetch("name")
    assert_equal "${{ always() }}", web_gate.fetch("if")
    assert_equal "web-tests", web_gate.fetch("needs")
    gate_step = web_gate.fetch("steps").find { |step| step["name"] == "Require Rails integration, system, and golden-path gates" }
    assert_equal "${{ needs.web-tests.result }}", gate_step.dig("env", "HIVE_WEB_TESTS_RESULT")
    assert_equal 'test "$HIVE_WEB_TESTS_RESULT" = "success"', gate_step.fetch("run")
    web_notice = web_gate.fetch("steps").find { |step| step["name"] == "Aggregation-only notice (no tests run in this job)" }
    assert web_notice, "web aggregate job must self-describe as an aggregator"
  end

  def test_incident_duration_budget_is_advisory_and_separate_from_functional_e2e
    workflow = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"), aliases: true)
    jobs = workflow.fetch("jobs")
    e2e = jobs.fetch("e2e")
    advisory = jobs.fetch("incident-duration-budget")
    incident_budget_script = "test/e2e/check_incident_budget.rb"

    e2e_steps = e2e.fetch("steps")
    integrity_steps = e2e_steps.select do |step|
      step.fetch("run", "").include?(incident_budget_script)
    end
    assert_equal 1, integrity_steps.length
    integrity = integrity_steps.fetch(0)
    assert_equal(
      'ruby test/e2e/check_incident_budget.rb "$HIVE_E2E_RUNS_DIR" --integrity-only',
      integrity.fetch("run")
    )
    refute_includes integrity.fetch("run"), "--timing-only"
    assert_equal "incident duration budget (advisory)", advisory.fetch("name")
    assert_equal "e2e", advisory.fetch("needs")
    assert_equal true, advisory.fetch("continue-on-error")

    ruby_setup = advisory.fetch("steps").find { |step| step["uses"] == "ruby/setup-ruby@v1" }
    assert_equal({ "ruby-version" => "3.4" }, ruby_setup.fetch("with"))
    refute advisory.fetch("steps").any? { |step| step.fetch("run", "").include?("bundle") }

    download = advisory.fetch("steps").find { |step| step["name"] == "Download e2e report" }
    assert_equal DOWNLOAD_ARTIFACT_ACTION, download.fetch("uses")
    assert_equal "hive-e2e-report", download.fetch("with").fetch("name")
    assert_equal "${{ runner.temp }}/hive-e2e-runs", download.fetch("with").fetch("path")

    enforce_steps = advisory.fetch("steps").select do |step|
      step.fetch("run", "").include?(incident_budget_script)
    end
    assert_equal 1, enforce_steps.length
    enforce = enforce_steps.fetch(0)
    assert_equal(
      'ruby test/e2e/check_incident_budget.rb "$HIVE_E2E_RUNS_DIR" --timing-only',
      enforce.fetch("run")
    )
    refute_includes enforce.fetch("run"), "--integrity-only"
    assert_equal(
      "${{ runner.temp }}/hive-e2e-runs",
      enforce.fetch("env").fetch("HIVE_E2E_RUNS_DIR")
    )

    scenario = e2e_steps.find { |step| step["name"] == "Run real-subprocess scenarios" }
    upload = e2e_steps.find { |step| step["uses"] == UPLOAD_ARTIFACT_ACTION }
    assert_equal download.fetch("with").fetch("name"), upload.fetch("with").fetch("name")
    assert_equal(
      scenario.fetch("env").fetch("HIVE_E2E_RUNS_DIR"),
      upload.fetch("with").fetch("path")
    )
    assert_equal(
      integrity.fetch("env").fetch("HIVE_E2E_RUNS_DIR"),
      upload.fetch("with").fetch("path")
    )
    assert_equal(
      enforce.fetch("env").fetch("HIVE_E2E_RUNS_DIR"),
      download.fetch("with").fetch("path")
    )
    assert_operator e2e_steps.index(upload), :>, e2e_steps.index(scenario)
    assert_operator e2e_steps.index(upload), :>, e2e_steps.index(integrity)

    required_needs = jobs.fetch("required-test-gate").fetch("needs")
    assert_includes required_needs, "e2e"
    refute_includes required_needs, "incident-duration-budget"
  end

  def test_ci_gate_tasks_fail_when_no_non_skipped_asserting_test_runs
    output, status = Open3.capture2e(
      { "HIVE_REQUIRE_TEST_RUNS" => "1" },
      RbConfig.ruby,
      "-I#{File.join(ROOT, "test")}",
      "-I#{File.join(ROOT, "lib")}",
      "-e",
      'require "test_helper"',
      chdir: ROOT
    )

    refute status.success?, output
    assert_includes output, "CI gate selected zero non-skipped tests with assertions"
  end

  def test_coverage_prepare_shard_rejects_invalid_metadata
    cases = [
      [ { "HIVE_COVERAGE_SHARD_INDEX" => nil }, "index, count, and run ID must be provided" ],
      [ { "HIVE_COVERAGE_SHARD_INDEX" => "nope" }, "index, count, and run ID must be provided" ],
      [ { "HIVE_COVERAGE_SHARD_INDEX" => "6" }, "coverage shard must be 0..5 of 6" ],
      [ { "HIVE_COVERAGE_SHARD_COUNT" => "5" }, "coverage shard must be 0..5 of 6" ],
      [ { "HIVE_COVERAGE_RUN_ID" => "" }, "HIVE_COVERAGE_RUN_ID must not be empty" ]
    ]
    baseline = {
      "HIVE_COVERAGE_SHARD_INDEX" => "0",
      "HIVE_COVERAGE_SHARD_COUNT" => "6",
      "HIVE_COVERAGE_RUN_ID" => "task-contract"
    }

    cases.each do |overrides, expected|
      output = capture_io do
        with_env(baseline.merge(overrides)) do
          with_loaded_rakefile do
            assert_raises(SystemExit) { Rake::Task["coverage:prepare_shard"].invoke }
          end
        end
      end.join
      assert_includes output, expected
    end
  end

  def test_coverage_prepare_shard_assigns_catalog_preload_to_first_collector_only
    { "0" => "1", "1" => "0", "5" => "0" }.each do |shard_index, expected|
      env = {
        "HIVE_COVERAGE_SHARD_INDEX" => shard_index,
        "HIVE_COVERAGE_SHARD_COUNT" => "6",
        "HIVE_COVERAGE_RUN_ID" => "preload-contract-#{shard_index}",
        "HIVE_COVERAGE" => nil,
        "HIVE_COVERAGE_ROOT" => nil,
        "HIVE_COVERAGE_COLLECT_ONLY" => nil,
        "HIVE_COVERAGE_LOAD_ALL" => nil,
        "HIVE_REQUIRE_TEST_RUNS" => nil,
        "RUBYOPT" => nil
      }

      with_env(env) do
        with_loaded_rakefile do
          with_replaced_singleton_method(FileUtils, :rm_rf, ->(_path) { }) do
            with_replaced_singleton_method(FileUtils, :rm_f, ->(_path) { }) do
              Rake::Task["coverage:prepare_shard"].invoke
            end
          end

          assert_equal expected, ENV.fetch("HIVE_COVERAGE_LOAD_ALL")
        end
      end
    end
  end

  def test_coverage_collect_rejects_missing_results_and_errors_then_writes_manifest
    coverage_state = coverage_state_snapshot
    run_id = "task-contract-#{Process.pid}"
    resultset = File.join(ROOT, "coverage", ".resultset", run_id)
    env = {
      "HIVE_COVERAGE_RUN_ID" => run_id,
      "HIVE_COVERAGE_SHARD_INDEX" => "0",
      "HIVE_COVERAGE_SHARD_COUNT" => "6",
      "HIVE_COVERAGE_REVISION" => "reviewed-head",
      "HIVE_COVERAGE_WORKFLOW_RUN_ID" => "1234"
    }
    FileUtils.rm_rf(resultset)
    FileUtils.mkdir_p(resultset)

    output = capture_io do
      with_env(env) do
        with_loaded_rakefile do
          task = Rake::Task["coverage:collect"]
          task.clear_prerequisites
          assert_raises(SystemExit) { task.invoke }
        end
      end
    end.join
    assert_includes output, "coverage shard wrote no process results"

    File.binwrite(File.join(resultset, "1-8.marshal"), Marshal.dump({}))
    File.write(File.join(resultset, "1-8.error.json"), JSON.dump(error_class: "IOError"))
    output = capture_io do
      with_env(env) do
        with_loaded_rakefile do
          task = Rake::Task["coverage:collect"]
          task.clear_prerequisites
          assert_raises(SystemExit) { task.invoke }
        end
      end
    end.join
    assert_includes output, "coverage shard recorded dump errors"

    FileUtils.rm_f(File.join(resultset, "1-8.error.json"))
    output = capture_io do
      with_env(env) do
        with_loaded_rakefile do
          task = Rake::Task["coverage:collect"]
          task.clear_prerequisites
          task.invoke
        end
      end
    end.join
    manifest = JSON.parse(File.read(File.join(resultset, "manifest.json")))
    assert_includes output, "Collected 1 coverage process result(s)"
    assert_equal HiveTestCoverage::SHARD_MANIFEST_SCHEMA, manifest.fetch("schema")
    assert_equal 0, manifest.fetch("shard_index")
    assert_equal [ "1-8.marshal" ], manifest.fetch("process_results")
    refute_empty manifest.fetch("test_files")
  ensure
    restore_coverage_state(coverage_state) if coverage_state
    FileUtils.rm_rf(resultset) if resultset
  end

  private

  def size_balanced_shards(files, count)
    shards = Array.new(count) { [] }
    byte_counts = Array.new(count, 0)
    files.sort_by { |path| [ -File.size(File.join(ROOT, path)), path ] }.each do |path|
      shard = byte_counts.each_index.min_by { |index| [ byte_counts[index], index ] }
      shards.fetch(shard) << path
      byte_counts[shard] += File.size(File.join(ROOT, path))
    end
    shards
  end

  def coverage_state_snapshot
    HiveTestCoverage.instance_variables.to_h do |ivar|
      [ ivar, HiveTestCoverage.instance_variable_get(ivar) ]
    end
  end

  def restore_coverage_state(snapshot)
    HiveTestCoverage.instance_variables.each do |ivar|
      HiveTestCoverage.remove_instance_variable(ivar) unless snapshot.key?(ivar)
    end
    snapshot.each { |ivar, value| HiveTestCoverage.instance_variable_set(ivar, value) }
  end

  def with_loaded_rakefile
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    load File.join(ROOT, "Rakefile")
    yield
  ensure
    RAKEFILE_CONSTANTS.each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
    Rake.application = previous_application
  end
end
