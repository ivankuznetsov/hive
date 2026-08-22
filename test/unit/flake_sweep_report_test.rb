require "test_helper"
require "digest"
require "json"
require "open3"

class FlakeSweepReportTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "script", "flake_sweep_report.rb")
  EXPECTED_SEEDS = [ 101, 202, 303 ].freeze

  def test_missing_required_seed_is_rejected_without_derived_artifacts
    with_reports(EXPECTED_SEEDS.first(2).map { |seed| report(seed:) }) do |paths, candidates, timings|
      output, status = run_report(paths, candidates, timings)

      refute status.success?
      assert_includes output, "expected seeds 101,202,303"
      refute_path_exists candidates
      refute_path_exists timings
    end
  end

  def test_same_count_with_different_suite_manifest_is_rejected
    reports = EXPECTED_SEEDS.map { |seed| report(seed:) }
    reports.last.replace(report(seed: 303, suite_files: [ "test/unit/other_test.rb" ]))

    with_reports(reports) do |paths, candidates, timings|
      output, status = run_report(paths, candidates, timings)

      refute status.success?
      assert_includes output, "suite manifest"
      refute_path_exists candidates
      refute_path_exists timings
    end
  end

  def test_complete_consistently_failing_matrix_writes_analysis_then_exits_nonzero
    failure = {
      "identifier" => "BrokenTest#test_breaks",
      "file" => "test/unit/sample_test.rb",
      "message" => "still broken"
    }
    reports = EXPECTED_SEEDS.map { |seed| report(seed:, failures: [ failure ]) }

    with_reports(reports) do |paths, candidates, timings|
      _output, status = run_report(paths, candidates, timings)

      refute status.success?
      candidate_payload = JSON.parse(File.read(candidates))
      assert_equal EXPECTED_SEEDS, candidate_payload.fetch("seeds")
      assert_equal [ "BrokenTest#test_breaks" ],
                   candidate_payload.fetch("consistently_failing").map { |entry| entry.fetch("test") }
      timing_payload = JSON.parse(File.read(timings))
      assert_equal "hive-shard-timings.v1", timing_payload.fetch("schema")
      assert_equal({ "test/unit/sample_test.rb" => 1.0 }, timing_payload.fetch("seconds_per_run"))
    end
  end

  private

  def report(seed:, suite_files: [ "test/unit/sample_test.rb" ], failures: [])
    {
      "schema" => "hive-flake-sweep-run.v1",
      "seed" => seed,
      "suite_files" => suite_files,
      "suite_manifest_sha256" => Digest::SHA256.hexdigest(suite_files.join("\0")),
      "tests_run" => 1,
      "per_file_seconds" => { suite_files.first => 1.0 },
      "failures" => failures
    }
  end

  def with_reports(reports)
    Dir.mktmpdir("flake-sweep-report") do |dir|
      paths = reports.each_with_index.map do |payload, index|
        File.join(dir, "report-#{index}.json").tap do |path|
          File.write(path, JSON.generate(payload))
        end
      end
      yield paths, File.join(dir, "candidates.json"), File.join(dir, "timings.json")
    end
  end

  def run_report(paths, candidates, timings)
    Open3.capture2e(
      RbConfig.ruby, SCRIPT,
      "--reports", paths.join(","),
      "--expected-seeds", EXPECTED_SEEDS.join(","),
      "--candidates", candidates,
      "--timings", timings,
      chdir: ROOT,
    )
  end
end
