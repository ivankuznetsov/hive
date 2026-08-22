require "test_helper"
require_relative "../support/coverage"
require_relative "../support/coverage_config_sandbox"
require "json"
require "tmpdir"

module TestCoverageEvidence
  class ExportTest < Minitest::Test
    include HiveCoverageConfigSandbox::TestHelpers

    def setup
      @tmp_root = Dir.mktmpdir("hive-cov-ev")
      configure_coverage_root!(@tmp_root)
    end

    # Restoring is load-bearing, not hygiene: leaving @resultset_dir pointed at
    # @tmp_root sends this process's own at_exit coverage dump into a deleted
    # scratch directory, silently dropping the whole shard's hits.
    def teardown
      restore_coverage_config!
      FileUtils.remove_entry(@tmp_root) if @tmp_root && File.directory?(@tmp_root)
    end

    def test_exports_every_uncovered_file_beyond_the_log_truncation_cap
      files = 40.times.map do |index|
        {
          "file" => "lib/hive/generated_#{index}.rb",
          "loaded" => true,
          "line_total" => 10,
          "line_covered" => 9,
          "line_percent" => 90.0,
          "uncovered_lines" => [ index + 1 ],
          "branch_total" => 0,
          "branch_covered" => 0,
          "branch_percent" => 100.0,
          "uncovered_branches" => []
        }
      end
      report = base_report.merge("files" => files)

      HiveTestCoverage.export_evidence!(report)
      payload = JSON.parse(File.read(File.join(@tmp_root, "coverage", "uncovered.json")))

      assert_equal "hive-coverage-uncovered.v1", payload.fetch("schema")
      refute payload.fetch("ok")
      assert_equal 40, payload.fetch("uncovered").length
      assert_equal "lib/hive/generated_7.rb", payload.fetch("uncovered").fetch(7).fetch("file")
      assert_equal [ 8 ], payload.fetch("uncovered").fetch(7).fetch("lines")
    end

    def test_fully_covered_tree_exports_an_empty_list_without_failure
      report = base_report.merge(
        "ok" => true,
        "line_covered" => 500.0,
        "line_total" => 500.0,
        "files" => [
          {
            "file" => "lib/hive/complete.rb",
            "line_total" => 500,
            "line_covered" => 500,
            "uncovered_lines" => [],
            "uncovered_branches" => []
          }
        ]
      )

      HiveTestCoverage.export_evidence!(report)
      payload = JSON.parse(File.read(File.join(@tmp_root, "coverage", "uncovered.json")))

      assert payload.fetch("ok")
      assert_empty payload.fetch("uncovered")
      assert_empty payload.fetch("unloaded_files")
    end

    def test_shard_map_matches_the_partition_used_by_the_run
      shards = [
        [ "test/unit/a_test.rb", "test/unit/b_test.rb" ],
        [ "test/integration/c_test.rb" ]
      ]

      HiveTestCoverage.export_shard_map!(shards)
      payload = JSON.parse(File.read(File.join(@tmp_root, "coverage", "shards.json")))

      assert_equal "hive-coverage-shard-map.v1", payload.fetch("schema")
      assert_equal [
        { "index" => 0, "test_files" => [ "test/unit/a_test.rb", "test/unit/b_test.rb" ] },
        { "index" => 1, "test_files" => [ "test/integration/c_test.rb" ] }
      ], payload.fetch("shards")
    end

    def test_export_failure_never_raises_or_masks_the_gate_result
      # coverage/uncovered.json as a directory forces every write to fail.
      FileUtils.mkdir_p(File.join(@tmp_root, "coverage", "uncovered.json"))
      report = base_report

      assert_silent do
        capture_io do
          HiveTestCoverage.export_evidence!(report)
        end
      end
    ensure
      FileUtils.remove_entry(@tmp_root) if @tmp_root && File.directory?(@tmp_root)
      @tmp_root = Dir.mktmpdir("hive-cov-ev")
      configure_coverage_root!(@tmp_root)
    end

    private

    def base_report
      {
        "ok" => false,
        "line_covered" => 499.0,
        "line_total" => 510.0,
        "minimum_line_percent" => 100.0,
        "unloaded_files" => [],
        "files" => []
      }
    end
  end
end
