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
      assert_equal %w[test expensive-test-gates], required_gate.fetch("needs")

      required_step = required_gate.fetch("steps").fetch(0)
      assert_equal "${{ needs.test.result }}",
                   required_step.fetch("env").fetch("HIVE_COVERAGE_RESULT")
      assert_equal "${{ needs.expensive-test-gates.result }}",
                   required_step.fetch("env").fetch("HIVE_EXPENSIVE_GATES_RESULT")
      assert_equal "bash", required_step.fetch("shell")
      assert_equal <<~SHELL, required_step.fetch("run")
        test "$HIVE_COVERAGE_RESULT" = "success"
        test "$HIVE_EXPENSIVE_GATES_RESULT" = "success"
      SHELL
    end
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
