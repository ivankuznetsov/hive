require "test_helper"
require "json"
require "shellwords"
require "tmpdir"

module TestFailureEvidenceUnit
  module Helpers
    def with_emission_env(summary_path, evidence_path)
      old_ci = ENV["CI"]
      old_summary = ENV["GITHUB_STEP_SUMMARY"]
      old_override = HiveFailureEvidence.evidence_path_override
      ENV["CI"] = "1"
      ENV["GITHUB_STEP_SUMMARY"] = summary_path
      HiveFailureEvidence.evidence_path_override = evidence_path
      yield
    ensure
      if old_ci
        ENV["CI"] = old_ci
      else
        ENV.delete("CI")
      end
      if old_summary
        ENV["GITHUB_STEP_SUMMARY"] = old_summary
      else
        ENV.delete("GITHUB_STEP_SUMMARY")
      end
      HiveFailureEvidence.evidence_path_override = old_override
    end

    def with_summary_var(summary_path)
      old_summary = ENV["GITHUB_STEP_SUMMARY"]
      ENV["GITHUB_STEP_SUMMARY"] = summary_path
      yield
    ensure
      if old_summary
        ENV["GITHUB_STEP_SUMMARY"] = old_summary
      else
        ENV.delete("GITHUB_STEP_SUMMARY")
      end
    end

    def passing_result
      result = Minitest::Result.from(sample_test_class(:test_ok).new(:test_ok))
      result.source_location = [ "test/unit/sample_test.rb", 20 ]
      result
    end

    def failing_result
      result = Minitest::Result.from(sample_test_class(:test_bites).new(:test_bites))
      result.source_location = [ "test/unit/sample_test.rb", 17 ]
      failure = Minitest::Assertion.new("expected 1, got 2")
      failure.set_backtrace([ "test/unit/sample_test.rb:17" ])
      result.failures << failure
      result
    end

    def sample_test_class(method_name)
      Class.new(Minitest::Test) do
        define_singleton_method(:name) { "SampleTest" }
        define_method(method_name) { assert_equal(1, 2) }
      end
    end
  end
  class HappyPathTest < Minitest::Test
    include Helpers

    def test_failing_suite_writes_summary_and_json_with_repro_command
      Dir.mktmpdir do |dir|
        summary_path = File.join(dir, "summary.md")
        evidence_path = File.join(dir, "nested", "evidence.json")

        reporter = HiveFailureEvidence::Reporter.new({ seed: 424_242 })
        reporter.record(failing_result)
        with_emission_env(summary_path, evidence_path) { reporter.report }

        summary = File.read(summary_path)
        assert_includes summary, "Failed tests (1)"
        assert_includes summary, "`SampleTest#test_bites`"
        expected_repro = Shellwords.join(
          %w[bundle exec ruby -Itest -Ilib test/unit/sample_test.rb --seed 424242 --name] +
          [ "SampleTest#test_bites" ]
        )
        assert_includes summary, "repro: `#{expected_repro}`"

        payload = JSON.parse(File.read(evidence_path))
        assert_equal "hive-ci-failure-evidence/v1", payload.fetch("schema")
        assert_equal 424_242, payload.fetch("seed")
        failure = payload.fetch("failures").fetch(0)
        assert_equal "SampleTest#test_bites", failure.fetch("test")
        assert_equal "test/unit/sample_test.rb", failure.fetch("file")
        assert_equal 17, failure.fetch("line")
        assert_includes failure.fetch("message"), "Minitest::Assertion"
        assert_equal expected_repro, failure.fetch("repro_command")
        refute payload.key?("quarantine_retries"),
               "failure evidence must not advertise a retry channel that CI does not use"
      end
    end
  end

  class EdgeCaseTest < Minitest::Test
    include Helpers

    def test_zero_failures_remove_stale_child_evidence_and_write_no_summary
      Dir.mktmpdir do |dir|
        summary_path = File.join(dir, "summary.md")
        evidence_path = File.join(dir, "evidence.json")
        File.write(evidence_path, "stale child evidence")

        reporter = HiveFailureEvidence::Reporter.new({ seed: 1 })
        with_emission_env(summary_path, evidence_path) { reporter.report }

        refute_path_exists summary_path
        refute_path_exists evidence_path
      end
    end

    def test_passing_results_are_not_recorded
      reporter = HiveFailureEvidence::Reporter.new({ seed: 1 })
      reporter.record(passing_result)

      assert_empty reporter.failures
    end

    def test_skipped_result_is_not_recorded
      result = passing_result
      def result.failures
        [ Minitest::Skip.new("skipped") ]
      end

      reporter = HiveFailureEvidence::Reporter.new({ seed: 1 })
      reporter.record(result)

      # A skip is neither an error nor a real failure; it must not produce
      # failure evidence.
      assert_empty reporter.failures
    end

    def test_result_without_source_location_still_reports
      result = failing_result
      def result.source_location
        raise NoMethodError, "stripped"
      end

      entry = HiveFailureEvidence::FailureEntry.from_result(result, 9)

      assert_nil entry.file
      assert_equal "SampleTest#test_bites", Shellwords.split(entry.repro_command).last
    end

    def test_source_location_inside_repo_is_portable
      result = failing_result
      result.source_location = [ File.join(HiveFailureEvidence::REPO_ROOT, "test/unit/sample_test.rb"), 17 ]

      entry = HiveFailureEvidence::FailureEntry.from_result(result, 9)

      assert_equal "test/unit/sample_test.rb", entry.file
    end
  end

  class ErrorPathTest < Minitest::Test
    include Helpers

    def test_emission_failure_never_raises_or_changes_exit_status
      Dir.mktmpdir do |dir|
        # A directory where a file is expected forces every write to fail.
        summary_path = File.join(dir, "summary-is-a-dir")
        evidence_path = File.join(dir, "evidence-is-a-dir")
        FileUtils.mkdir(summary_path)
        FileUtils.mkdir(File.join(dir, "nested"))
        FileUtils.mkdir(File.join(dir, "nested", "evidence.json"))

        reporter = HiveFailureEvidence::Reporter.new({ seed: 2 })
        reporter.record(failing_result)

        assert_output(nil, /emission failed \(ignored\)/) do
          with_emission_env(summary_path, evidence_path) { reporter.report }
        end
      end
    end

    def test_report_without_ci_environment_is_inert
      Dir.mktmpdir do |dir|
        summary_path = File.join(dir, "summary.md")
        reporter = HiveFailureEvidence::Reporter.new({ seed: 3 })
        reporter.record(failing_result)

        ci_was = ENV.delete("CI")
        begin
          with_summary_var(summary_path) { reporter.report }
        ensure
          ENV["CI"] = ci_was
        end

        refute_path_exists summary_path
      end
    end
  end
end
