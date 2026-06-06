require "eval/eval_helper"
require "fileutils"
require "json"
require "open3"

class HiveEvalReporterTest < Minitest::Test
  def test_cli_writes_report_for_passing_scenario
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "s1.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
      )

      assert status.success?, err
      doc = JSON.parse(File.read(report))
      assert_equal "hive-eval-report", doc.fetch("schema")
      assert_equal 2, doc.fetch("scenarios").length
      assert doc.fetch("scenarios").all? { |entry| entry.fetch("status") == "pass" }
    end
  end

  def test_cli_rejects_traversal_scenario_basename_without_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "escape.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "../../unit/hv", "--no-judge", "--report", report
      )

      assert_equal 64, status.exitstatus
      assert_match(/scenario must be a safe basename/, err)
      refute File.exist?(report), "invalid scenario names must not write an eval report"
    end
  end

  def test_cli_reports_failing_scenario_and_exits_nonzero
    # s3_noise used to be the always-failing scenario the reporter exercised.
    # Now that daemon-gated ready_to_X suppression has landed (commit
    # 0aa16678), s3_noise passes — which is the correct production
    # behavior. Write a tmpdir-scoped fixture that asserts a deliberate
    # failure so we still exercise the reporter's failure path (exit
    # nonzero + report shape + per-scenario "fail" status) without
    # coupling to any specific production bug.
    #
    # The fixture scenario lives in a throwaway scenario root
    # (HIVE_EVAL_SCENARIO_ROOT) inside the tmpdir, never in the real
    # test/eval/scenarios/ source tree: a SIGKILL between write and
    # cleanup would otherwise leak a `*_test.rb` that a later full eval
    # run would execute. Dir.mktmpdir cleans the whole tree regardless.
    Dir.mktmpdir("hive-eval-report") do |dir|
      scenario_root = File.join(dir, "scenarios")
      FileUtils.mkdir_p(scenario_root)
      scenario_name = "intentional_failure"
      fixture = File.join(scenario_root, "#{scenario_name}_test.rb")
      File.write(fixture, <<~RUBY)
        require "eval/eval_helper"

        class HiveEvalIntentionalFailureFixture < Minitest::Test
          include Hive::Eval::ScenarioSupport

          def test_intentional_failure_for_reporter_contract
            given_project(name: "hive")
            assert false, "intentional failure for HiveEvalReporterTest fixture"
          end
        end
      RUBY
      report = File.join(dir, "failure.json")

      _out, _err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1", "HIVE_EVAL_SCENARIO_ROOT" => scenario_root },
        "bin/hive-eval", "--scenario", scenario_name, "--no-judge", "--report", report
      )

      refute status.success?, "fixture asserts false; reporter CLI must exit nonzero on failure"
      doc = JSON.parse(File.read(report))
      assert_equal "hive-eval-report", doc.fetch("schema")
      entry = doc.fetch("scenarios").fetch(0)
      assert_equal "fail", entry.fetch("status")
      assert_match(/intentional failure for HiveEvalReporterTest fixture/,
                   entry.fetch("failures").join("\n"))
    end
  end

  def test_cli_rejects_scenario_paths_outside_scenario_dir
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "outside.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "test/eval/support/reporter_test.rb", "--no-judge", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/scenario must be a basename/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_scenario_with_backslash_path_separator
    # The backslash branch of scenario_path raises the same
    # "must be a basename" error as the slash branch (Windows-style
    # separators are rejected too), distinct from the safe-basename raise.
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "backslash.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", 'evil\\scenario', "--no-judge", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/scenario must be a basename/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_unsafe_scenario_basename
    # A separator-free name that still contains characters outside
    # [\w-] (here a dot) trips the distinct "safe basename" raise, not
    # the basename/separator one.
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "unsafe.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "s1.status", "--no-judge", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/scenario must be a safe basename/, err)
      refute File.exist?(report)
    end
  end
end
