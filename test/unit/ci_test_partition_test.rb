require "test_helper"
require "rake"
require "yaml"

class CiTestPartitionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  RAKEFILE_CONSTANTS = %i[HIVE_CI_GATE_TESTS HIVE_DEFAULT_TEST_FILES].freeze

  def test_default_suite_excludes_the_expensive_ci_gates
    with_loaded_rakefile do
      gate_tests = Object.const_get(:HIVE_CI_GATE_TESTS)
      gate_files = gate_tests.values
      default_files = Object.const_get(:HIVE_DEFAULT_TEST_FILES).to_a

      assert_equal({
        "test:packaged_web_bootstrap" => "test/integration/web_packaged_bootstrap_test.rb",
        "test:tui_reactivity_perf" => "test/integration/tui_reactivity_perf_test.rb"
      }, gate_tests)
      gate_files.each { |file| assert_path_exists File.join(ROOT, file) }
      assert_empty default_files & gate_files
      assert_equal gate_tests.keys.sort, Rake::Task.tasks.filter_map { |task|
        task.name if task.name.start_with?("test:") && gate_tests.key?(task.name)
      }.sort
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
        }
      ], matrix
      assert_equal "${{ matrix.name }}", gate_job.fetch("name")
      assert_equal Object.const_get(:HIVE_CI_GATE_TESTS).keys, matrix.map { |entry| entry.fetch("task") }

      run_step = gate_job.fetch("steps").find { |step| step["name"] == "Run merge gate" }
      assert_equal 'bundle exec rake "$HIVE_CI_GATE_TASK"', run_step.fetch("run")
      assert_equal "${{ matrix.task }}", run_step.fetch("env").fetch("HIVE_CI_GATE_TASK")
    end
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
