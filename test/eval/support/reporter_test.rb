require "eval/eval_helper"
require "fileutils"
require "json"
require "open3"

class HiveEvalReporterTest < Minitest::Test
  def test_cli_rejects_positional_scenario_argument
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "positional.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "s1_status", "--no-judge", "--report", report
      )

      assert_equal 64, status.exitstatus
      assert_match(/unexpected argument\(s\): s1_status/, err)
      refute File.exist?(report), "unexpected positional args must exit before running eval scenarios"
    end
  end

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

  def test_cli_ignores_ambient_test_when_running_all_scenarios
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "all.json")

      _out, err, _status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1", "TEST" => "test/unit/config_test.rb" },
        "bin/hive-eval", "--no-judge", "--report", report
      )

      assert File.exist?(report), "expected hive-eval to write an eval report, not run ambient TEST: #{err}"
      doc = JSON.parse(File.read(report))
      files = doc.fetch("scenarios").map { |entry| entry.fetch("file") }
      refute_empty files
      assert files.all? { |file| file.include?("/test/eval/scenarios/") }, files.join("\n")
      refute_includes files, File.expand_path("test/unit/config_test.rb")
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

  def test_cli_ignores_inherited_test_when_running_all_scenarios
    Dir.mktmpdir("hive-eval-report") do |dir|
      root = File.expand_path("../../..", __dir__)
      scenario_dir = File.join(root, "test", "eval", "scenarios") + File::SEPARATOR
      report = File.join(dir, "all.json")

      _out, err, _status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1", "TEST" => "test/eval/support/scaffold_test.rb" },
        "bin/hive-eval", "--no-judge", "--report", report
      )

      assert File.exist?(report), err
      files = JSON.parse(File.read(report))
        .fetch("scenarios")
        .map { |entry| File.expand_path(entry.fetch("file"), root) }

      refute_empty files
      assert files.all? { |file| file.start_with?(scenario_dir) },
             "expected only scenario files, got #{files.inspect}"
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

  def test_cli_rejects_invalid_option_as_usage_error
    _out, err, status = Open3.capture3(
      { "HIVE_EVAL_NO_JUDGE" => "1" },
      "bin/hive-eval", "--bogus"
    )

    refute status.success?
    assert_equal 64, status.exitstatus
    assert_match(/hive-eval: invalid option: --bogus/, err)
    refute_match(/OptionParser::/, err)
  end

  def test_cli_rejects_missing_scenario_value_as_usage_error
    _out, err, status = Open3.capture3(
      { "HIVE_EVAL_NO_JUDGE" => "1" },
      "bin/hive-eval", "--scenario"
    )

    refute status.success?
    assert_equal 64, status.exitstatus
    assert_match(/hive-eval: missing argument: --scenario/, err)
    refute_match(/OptionParser::/, err)
  end

  def test_cli_rejects_missing_report_value_as_usage_error
    _out, err, status = Open3.capture3(
      { "HIVE_EVAL_NO_JUDGE" => "1" },
      "bin/hive-eval", "--report"
    )

    refute status.success?
    assert_equal 64, status.exitstatus
    assert_match(/hive-eval: missing argument: --report/, err)
    refute_match(/OptionParser::/, err)
  end

  def test_cli_rejects_unexpected_positional_arguments
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "unexpected.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report, "extra"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/hive-eval: unexpected argument\(s\): extra/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_unknown_options_with_usage
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "unknown-option.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--bogus", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/invalid option: --bogus/, err)
      assert_match(%r{Usage: bin/hive-eval}, err)
      refute_match(/OptionParser::/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_missing_option_values_with_usage
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "missing-scenario.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--report", report, "--scenario"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/missing argument: --scenario/, err)
      assert_match(%r{Usage: bin/hive-eval}, err)
      refute_match(/OptionParser::/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_stray_positional_scenario_names
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "positional.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "definitely-not-a-scenario", "--no-judge", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/unexpected argument\(s\): definitely-not-a-scenario/, err)
      assert_match(%r{Usage: bin/hive-eval}, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_path_separators_in_scenario_basename
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "traversal.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "../../unit/invoked_binary", "--no-judge", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/scenario basename must not contain path separators/, err)
      refute File.exist?(report)
    end
  end
end
