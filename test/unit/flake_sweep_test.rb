require "test_helper"
require "json"
require "open3"

class FlakeSweepTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "script", "flake_sweep.rb")

  def test_runner_loads_minitest_before_registering_reporter_and_emits_manifest
    Dir.mktmpdir("flake-sweep-start") do |dir|
      fixture = File.join(dir, "sample_test.rb")
      report = File.join(dir, "report.json")
      File.write(fixture, <<~RUBY)
        class SweepSampleTest < Minitest::Test
          def test_ok = assert true
        end
      RUBY

      output, status = Open3.capture2e(
        { "HIVE_SWEEP_TEST_FILES" => fixture },
        RbConfig.ruby, SCRIPT, "--seed", "101", "--report", report,
        chdir: ROOT,
      )

      assert status.success?, output
      payload = JSON.parse(File.read(report))
      assert_equal "hive-flake-sweep-run.v1", payload.fetch("schema")
      assert_equal 101, payload.fetch("seed")
      assert_equal [ fixture ], payload.fetch("suite_files")
      assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("suite_manifest_sha256"))
      assert_equal 1, payload.fetch("tests_run")
    end
  end
end
