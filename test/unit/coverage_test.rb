require "test_helper"
require_relative "../support/coverage"

class HiveTestCoverageTest < Minitest::Test
  include HiveTestHelper

  COVERAGE_STATE_IVARS = %i[@root @lib_dir @coverage_dir @resultset_dir @result_errors].freeze

  def test_unloaded_source_file_counts_executable_lines_as_uncovered
    with_tmp_dir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "demo.rb"), <<~RUBY)
        module DemoCoverageProbe
          VALUE = 1
        end
      RUBY

      with_coverage_config(root: dir) do
        report = HiveTestCoverage.build_report({})
        file = report.fetch(:files).fetch(0)

        assert_equal "lib/demo.rb", file.fetch(:file)
        assert_equal false, file.fetch(:loaded)
        assert_operator file.fetch(:line_total), :>, 0
        assert_equal 0, file.fetch(:line_covered)
        assert_equal 0.0, file.fetch(:line_percent)
        assert_equal file.fetch(:line_total), file.fetch(:uncovered_lines).size
        assert_includes report.fetch(:unloaded_files), "lib/demo.rb"
        refute report.fetch(:ok)
      end
    end
  end

  def test_unreadable_result_files_fail_the_gate
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))

      with_coverage_config(root: dir) do
        resultset_dir = HiveTestCoverage.instance_variable_get(:@resultset_dir)
        FileUtils.mkdir_p(resultset_dir)
        File.write(File.join(resultset_dir, "bad.marshal"), "not marshal")

        result = HiveTestCoverage.merged_results
        report = HiveTestCoverage.build_report(
          result,
          result_errors: HiveTestCoverage.instance_variable_get(:@result_errors)
        )

        refute HiveTestCoverage.coverage_ok?(report)
        assert_equal 1, report.fetch(:result_errors).size
        assert_includes HiveTestCoverage.failure_message(report), "unreadable subprocess coverage results"
      end
    end
  end

  def test_config_mismatch_surfaces_specific_error_not_unloaded_file_avalanche
    # Simulates a subprocess that wrote a valid marshal whose entries
    # point at a *different* source tree than @lib_dir. The harness should
    # fail with a clear configuration error rather than reporting every
    # file as unloaded.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "demo.rb"), "module Demo; end\n")

      with_coverage_config(root: dir) do
        resultset_dir = HiveTestCoverage.instance_variable_get(:@resultset_dir)
        FileUtils.mkdir_p(resultset_dir)
        # Marshal contains a path that doesn't live under dir/lib/ at all.
        File.binwrite(
          File.join(resultset_dir, "wrong-tree.marshal"),
          Marshal.dump({ "/elsewhere/some_other_lib/file.rb" => { lines: [ 1, 1 ], branches: {} } })
        )

        HiveTestCoverage.merged_results
        errors = HiveTestCoverage.instance_variable_get(:@result_errors)

        assert_equal 1, errors.size
        assert_equal "ConfigurationError", errors.first.fetch(:error_class)
        assert_includes errors.first.fetch(:message), "no entries matched"
      end
    end
  end

  def test_coverage_gate_accepts_string_keyed_json_report
    report = {
      "line_total" => 3,
      "line_covered" => 3,
      "unloaded_files" => [],
      "result_errors" => []
    }

    assert HiveTestCoverage.coverage_ok?(report)
  end


  def test_coverage_gate_honors_min_line_threshold_env
    report = {
      "line_total" => 4,
      "line_covered" => 2,
      "line_percent" => 50.0,
      "unloaded_files" => [],
      "result_errors" => []
    }

    with_env("HIVE_COVERAGE_MIN_LINE" => "75") do
      refute HiveTestCoverage.coverage_ok?(report)
      assert_includes HiveTestCoverage.failure_message(report), "below minimum 75.00%"
    end
  end

  private

  def with_coverage_config(root:)
    sentinel = Object.new
    old = COVERAGE_STATE_IVARS.to_h do |ivar|
      value = if HiveTestCoverage.instance_variable_defined?(ivar)
        HiveTestCoverage.instance_variable_get(ivar)
      else
        sentinel
      end
      [ ivar, value ]
    end

    HiveTestCoverage.configure!(root: root)
    yield
  ensure
    old&.each do |ivar, value|
      if value.equal?(sentinel)
        HiveTestCoverage.remove_instance_variable(ivar) if HiveTestCoverage.instance_variable_defined?(ivar)
      else
        HiveTestCoverage.instance_variable_set(ivar, value)
      end
    end
  end
end
