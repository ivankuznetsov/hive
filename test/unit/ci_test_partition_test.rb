require "test_helper"
require "open3"
require "rake"
require "yaml"

class CiTestPartitionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  RAKEFILE_CONSTANTS = %i[
    HIVE_CI_GATE_TESTS
    HIVE_CI_GATE_TEST_OPTIONS
    HIVE_DEFAULT_TEST_FILES
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

      assert_equal "coverage (Ruby ${{ matrix.ruby }})", workflow.fetch("jobs").fetch("test").fetch("name")
      required_gate = workflow.fetch("jobs").fetch("required-test-gate")
      assert_equal "rake test (Ruby 3.4)", required_gate.fetch("name")
      assert_equal "${{ always() }}", required_gate.fetch("if")
      assert_equal %w[test expensive-test-gates e2e], required_gate.fetch("needs")

      required_step = required_gate.fetch("steps").fetch(0)
      assert_equal "Require coverage, functional e2e, and expensive proof gates",
                   required_step.fetch("name")
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
    assert_equal "actions/download-artifact@v8", download.fetch("uses")
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
    upload = e2e_steps.find { |step| step["uses"] == "actions/upload-artifact@v7" }
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

  private

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
