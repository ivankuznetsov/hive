require "eval/eval_helper"
require "fileutils"
require "json"
require "open3"
require "timeout"

class HiveEvalReporterTest < Minitest::Test
  def test_cli_rejects_positional_scenario_argument
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "positional.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "s1_status", "--no-judge", "--report", report
      )

      assert_equal 64, status.exitstatus
      assert_match(/unexpected argument: s1_status/, err)
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

  def test_cli_rejects_inherited_rake_dry_run
    [ "-n", "-nT", "-vn", "--dr", "--dry", "--dry-r", "--dry_run", '"-n"', '"' ].each do |rakeopt|
      Dir.mktmpdir("hive-eval-report") do |dir|
        report = File.join(dir, "dry-run.json")

        _out, err, status = Open3.capture3(
          { "HIVE_EVAL_NO_JUDGE" => "1", "RAKEOPT" => rakeopt },
          "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
        )

        refute status.success?, "RAKEOPT=#{rakeopt.inspect} must not turn a skipped eval into success"
        assert_match(/RAKEOPT/, err)
        refute File.exist?(report)
      end
    end
  end

  def test_cli_clears_inherited_rake_options_from_child
    [ "--trace", "-Iinclude", "-Wno", "-fn" ].each do |rakeopt|
      Dir.mktmpdir("hive-eval-report") do |dir|
        report = File.join(dir, "valid.json")

        with_fake_bundle do |env, marker|
          env["RAKEOPT"] = rakeopt
          env["HIVE_EVAL_FAKE_REPORT"] = fake_report(file: "fake-scenario.rb")
          _out, err, status = Open3.capture3(
            env,
            "bin/hive-eval", "--no-judge", "--report", report
          )

          assert status.success?, "RAKEOPT=#{rakeopt.inspect}: #{err}"
          assert_equal "nil", File.readlines(marker, chomp: true).first
        end
      end
    end
  end

  def test_cli_rejects_successful_child_without_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "missing.json")

      with_fake_bundle do |env, marker|
        _out, err, status = Open3.capture3(
          env,
          "bin/hive-eval", "--no-judge", "--report", report
        )

        assert File.exist?(marker), "fake bundle must exercise the post-rake report check"
        refute status.success?, "a zero child exit without an eval report must fail"
        assert_match(/report/, err)
      end
    end
  end

  def test_cli_rejects_malformed_or_incomplete_success_report
    invalid_reports = {
      "malformed JSON" => "{",
      "wrong schema" => JSON.dump({
        "schema" => "not-hive-eval-report",
        "schema_version" => 1,
        "scenarios" => [ { "file" => File.expand_path("test/eval/scenarios/s1_status_test.rb") } ]
      }),
      "empty scenarios" => JSON.dump({
        "schema" => "hive-eval-report",
        "schema_version" => 1,
        "scenarios" => []
      }),
      "invalid scenario entry" => JSON.dump({
        "schema" => "hive-eval-report",
        "schema_version" => 1,
        "scenarios" => [ {} ]
      }),
      "failed scenario on zero exit" => fake_report(file: "fake-scenario.rb", status: "fail"),
      "wrong scenario" => fake_report(
        file: File.expand_path("test/eval/scenarios/s2_agent_question_test.rb")
      )
    }

    invalid_reports.each do |label, contents|
      Dir.mktmpdir("hive-eval-report") do |dir|
        report = File.join(dir, "invalid.json")

        with_fake_bundle do |env, _marker|
          env["HIVE_EVAL_FAKE_REPORT"] = contents
          _out, err, status = Open3.capture3(
            env,
            "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
          )

          refute status.success?, "#{label} must not be accepted as a successful eval"
          assert_match(/hive-eval-report/, err)
        end
      end
    end
  end

  def test_cli_does_not_validate_another_concurrent_runs_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "shared.json")
      ready = File.join(dir, "first-child-ready")
      release = File.join(dir, "release-first-child")
      first_result = nil
      first_thread = nil

      with_fake_bundle do |base_env, _marker|
        first_env = base_env.merge(
          "HIVE_EVAL_FAKE_READY" => ready,
          "HIVE_EVAL_FAKE_RELEASE" => release
        )
        first_thread = Thread.new do
          first_result = Open3.capture3(first_env, "bin/hive-eval", "--no-judge", "--report", report)
        end

        Timeout.timeout(5) { sleep 0.01 until File.exist?(ready) }

        second_env = base_env.merge(
          "HIVE_EVAL_FAKE_REPORT" => fake_report(file: "second-scenario.rb")
        )
        _out, second_err, second_status = Open3.capture3(
          second_env, "bin/hive-eval", "--no-judge", "--report", report
        )
        assert second_status.success?, second_err

        File.write(release, "continue\n")
        first_thread.join
        _first_out, first_err, first_status = first_result

        refute first_status.success?, "a child that wrote no private report must fail"
        assert_match(/hive-eval-report was not created/, first_err)
        assert_equal "second-scenario.rb", JSON.parse(File.read(report)).dig("scenarios", 0, "file")
      ensure
        File.write(release, "continue\n") unless File.exist?(release)
        first_thread&.join(2)
      end
    end
  end

  def test_cli_rejects_insecure_report_directory_before_running_child
    Dir.mktmpdir("hive-eval-report") do |dir|
      report_dir = File.join(dir, "shared")
      FileUtils.mkdir_p(report_dir)
      File.chmod(0o777, report_dir)
      report = File.join(report_dir, "report.json")
      original = "existing report\n"
      File.write(report, original)

      with_fake_bundle do |env, marker|
        env["HIVE_EVAL_FAKE_REPORT"] = fake_report(file: "fake-scenario.rb")
        _out, err, status = Open3.capture3(env, "bin/hive-eval", "--no-judge", "--report", report)

        refute status.success?
        assert_match(/group\/world-writable without the sticky bit/, err)
        refute File.exist?(marker), "the child must not run with an insecure report parent"
        assert_equal original, File.read(report)
      end
    end
  end

  def test_cli_cleanup_warning_does_not_override_success
    Dir.mktmpdir("hive-eval-report") do |dir|
      report_dir = File.join(dir, "report-dir")
      FileUtils.mkdir_p(report_dir)
      report = File.join(report_dir, "report.json")

      with_fake_bundle do |env, _marker|
        env["HIVE_EVAL_FAKE_REPORT"] = fake_report(file: "fake-scenario.rb")
        env["HIVE_EVAL_FAKE_INSECURE_PARENT"] = "1"
        _out, err, status = Open3.capture3(env, "bin/hive-eval", "--no-judge", "--report", report)

        assert status.success?, err
        assert_match(/could not remove private report directory/, err)
        assert_equal "fake-scenario.rb", JSON.parse(File.read(report)).dig("scenarios", 0, "file")
      end
    ensure
      File.chmod(0o700, report_dir) if report_dir && File.exist?(report_dir)
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

  def test_cli_clears_inherited_no_judge_env_when_judge_enabled
    Dir.mktmpdir("hive-eval-report") do |dir|
      scenario_root = File.join(dir, "scenarios")
      FileUtils.mkdir_p(scenario_root)
      scenario_name = "assert_judge_env"
      File.write(File.join(scenario_root, "#{scenario_name}_test.rb"), <<~RUBY)
        require "eval/eval_helper"

        class HiveEvalInheritedNoJudgeFixture < Minitest::Test
          include Hive::Eval::ScenarioSupport

          def test_inherited_no_judge_env_is_cleared
            assert_nil ENV["HIVE_EVAL_NO_JUDGE"]
          end
        end
      RUBY
      report = File.join(dir, "judge-enabled.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1", "HIVE_EVAL_SCENARIO_ROOT" => scenario_root },
        "bin/hive-eval", "--scenario", scenario_name, "--report", report
      )

      assert status.success?, err
      doc = JSON.parse(File.read(report))
      refute_empty doc.fetch("scenarios")
      assert_equal "pass", doc.fetch("scenarios").fetch(0).fetch("status")
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
      assert_match(/scenario basename must not contain path separators/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_scenario_with_backslash_path_separator
    # Windows-style separators are rejected too, distinct from the
    # safe-basename raise.
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "backslash.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", 'evil\\scenario', "--no-judge", "--report", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/scenario basename must not contain path separators/, err)
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

  def test_cli_rejects_report_value_that_looks_like_option
    with_fake_bundle do |env, marker|
      _out, err, status = Open3.capture3(
        env,
        "bin/hive-eval", "--report", "--no-judge"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/hive-eval: missing argument: --report/, err)
      refute_match(/OptionParser::/, err)
      refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
    end
  end

  def test_cli_usage_error_clears_default_report_for_option_looking_value
    # When --report's value is option-looking or empty (`--report --no-judge`,
    # `--report=`), parse! overwrites options[:report] with that junk token before
    # raising the missing-argument error. The usage-error cleanup must fall back to
    # the true default report path and clear a stale report there, honouring the
    # "no stale report" contract — not chase the junk token to a path that never
    # held a report.
    root = File.expand_path("../../..", __dir__)
    default_report = File.join(root, "tmp", "hive-eval-report.json")
    FileUtils.mkdir_p(File.dirname(default_report))

    [ [ "--report", "--no-judge" ], [ "--report=" ] ].each do |argv|
      preserve_path(default_report) do
        File.write(default_report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

        with_fake_bundle do |env, marker|
          _out, err, status = Open3.capture3(env, "bin/hive-eval", *argv)

          refute status.success?, "#{argv.inspect} must be a usage error"
          assert_equal 64, status.exitstatus, err
          assert_match(/hive-eval: missing argument: --report/, err)
          refute File.exist?(default_report),
                 "#{argv.inspect}: usage error must clear the stale default report, not a junk token"
          refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
        end
      end
    end
  end

  def test_cli_invalid_byte_report_value_preserves_selected_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "stale\xFF.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      with_fake_bundle do |env, marker|
        _out, err, status = Open3.capture3(
          env,
          "bin/hive-eval", "--report=#{report}", "--no-judge"
        )

        refute status.success?
        assert_equal 64, status.exitstatus
        assert_match(/hive-eval: invalid byte sequence in UTF-8/, err)
        assert_match(%r{Usage: bin/hive-eval}, err)
        refute_match(/ArgumentError/, err)
        assert File.exist?(report), "parser errors must not delete a caller-provided report path"
        refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
      end
    end
  end

  def test_cli_rejects_report_value_that_consumes_scenario_flag
    with_fake_bundle do |env, marker|
      _out, err, status = Open3.capture3(
        env,
        "bin/hive-eval", "--report", "--scenario", "s1_status"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/hive-eval: missing argument: --report/, err)
      assert_match(%r{Usage: bin/hive-eval}, err)
      refute_match(/OptionParser::/, err)
      refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
    end
  end

  def test_cli_rejects_scenario_value_that_looks_like_option_and_preserves_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "stale.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      with_fake_bundle do |env, marker|
        _out, err, status = Open3.capture3(
          env,
          "bin/hive-eval", "--scenario", "--no-judge", "--report", report
        )

        refute status.success?
        assert_equal 64, status.exitstatus
        assert_match(/hive-eval: missing argument: --scenario/, err)
        assert_match(%r{Usage: bin/hive-eval}, err)
        refute_match(/OptionParser::/, err)
        assert File.exist?(report), "parser errors must not delete a caller-provided report path"
        refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
      end
    end
  end

  def test_cli_rejects_scenario_consuming_report_flag_and_preserves_named_report
    # `--scenario --report <path>` makes --scenario swallow the --report flag
    # itself, leaving <path> a stray positional. Even though the pre-parse ARGV
    # snapshot still shows the named report, parser errors must not delete a
    # caller-provided path.
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "stale.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      with_fake_bundle do |env, marker|
        _out, err, status = Open3.capture3(
          env,
          "bin/hive-eval", "--scenario", "--report", report
        )

        refute status.success?
        assert_equal 64, status.exitstatus
        assert_match(/hive-eval: missing argument: --scenario/, err)
        assert_match(%r{Usage: bin/hive-eval}, err)
        refute_match(/OptionParser::/, err)
        assert File.exist?(report), "parser errors must not delete a caller-provided report path"
        refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
      end
    end
  end

  def test_cli_rejects_unexpected_positional_arguments
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "unexpected.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report, "extra", "bonus"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/hive-eval: unexpected arguments: extra bonus/, err)
      refute_match(/argument\(s\)/, err)
      assert File.exist?(report), "unexpected positional args must not delete a caller-provided report path"
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

  def test_cli_rejects_abbreviated_report_flag_with_usage
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "abbrev.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--rep", report
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/invalid option: --rep/, err)
      assert_match(%r{Usage: bin/hive-eval}, err)
      refute_match(/OptionParser::/, err)
      refute File.exist?(report)
    end
  end

  def test_cli_rejects_missing_option_values_with_usage
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "missing-scenario.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--report", report, "--scenario"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/missing argument: --scenario/, err)
      assert_match(%r{Usage: bin/hive-eval}, err)
      refute_match(/OptionParser::/, err)
      assert File.exist?(report), "missing option values must not delete a caller-provided report path"
    end
  end

  def test_cli_missing_scenario_preserves_existing_selected_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "stale.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--report", report, "--scenario", "definitely_missing", "--no-judge"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/scenario not found/, err)
      assert File.exist?(report), "missing scenarios must not delete a caller-provided report path"
    end
  end

  def test_cli_usage_errors_preserve_existing_non_report_files
    cases = [
      [
        "parse error",
        ->(report) { [ "--report", report, "--scenario" ] },
        /missing argument: --scenario/
      ],
      [
        "unexpected positional",
        ->(report) { [ "--scenario", "s1_status", "--no-judge", "--report", report, "extra" ] },
        /unexpected argument: extra/
      ],
      [
        "missing scenario",
        ->(report) { [ "--report", report, "--scenario", "definitely_missing", "--no-judge" ] },
        /scenario not found/
      ]
    ]

    cases.each do |label, argv_for, message|
      Dir.mktmpdir("hive-eval-report") do |dir|
        report = File.join(dir, "#{label.tr(" ", "-")}.txt")
        File.write(report, "keep me")

        _out, err, status = Open3.capture3(
          { "HIVE_EVAL_NO_JUDGE" => "1" },
          "bin/hive-eval", *argv_for.call(report)
        )

        refute status.success?, "#{label} must be a usage error"
        assert_equal 64, status.exitstatus, err
        assert_match(message, err)
        assert_equal "keep me", File.read(report), "#{label} must preserve existing non-report files"
      end
    end
  end

  def test_cli_invalid_invocations_preserve_non_report_files_passed_as_report
    Dir.mktmpdir("hive-eval-report") do |dir|
      cases = [
        [ "parse error", [ "--report", :report, "--bogus" ], /invalid option: --bogus/ ],
        [ "missing scenario", [ "--report", :report, "--scenario", "definitely_missing", "--no-judge" ], /scenario not found/ ]
      ]

      cases.each do |label, argv_template, expected_error|
        report = File.join(dir, "#{label.tr(" ", "-")}.txt")
        contents = "not a hive eval report\n"
        File.write(report, contents)
        argv = argv_template.map { |arg| arg == :report ? report : arg }

        _out, err, status = Open3.capture3(
          { "HIVE_EVAL_NO_JUDGE" => "1" },
          "bin/hive-eval", *argv
        )

        refute status.success?
        assert_equal 64, status.exitstatus, err
        assert_match(expected_error, err)
        assert_equal contents, File.read(report), "#{label} must not delete a non-report file"
      end
    end
  end

  def test_cli_report_link_to_non_report_file_is_not_followed
    # A --report path that is a symlink or hard link to an unrelated file must
    # not be followed when the report is written: the report lands on a fresh
    # regular file (its own inode) and the linked target is left untouched.
    # Otherwise File.write in ReportStore.write! would clobber the target the
    # link points at.
    link_kinds = {
      "symlink" => ->(target, report) { File.symlink(target, report) },
      "hard link" => ->(target, report) { File.link(target, report) }
    }

    link_kinds.each do |kind, make_link|
      Dir.mktmpdir("hive-eval-report") do |dir|
        target = File.join(dir, "precious.txt")
        target_contents = "do not clobber me via #{kind}\n"
        File.write(target, target_contents)

        report = File.join(dir, "report.json")
        make_link.call(target, report)

        _out, err, status = Open3.capture3(
          { "HIVE_EVAL_NO_JUDGE" => "1" },
          "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
        )

        assert status.success?, "#{kind}: #{err}"
        assert_equal target_contents, File.read(target),
          "#{kind}: writing the report must not follow the link and clobber its target"
        refute File.symlink?(report),
          "#{kind}: the report path must be replaced with a fresh regular file, not a #{kind}"
        refute_equal File.stat(target).ino, File.stat(report).ino,
          "#{kind}: the report must land on a fresh inode, not the linked target's"
        doc = JSON.parse(File.read(report))
        assert_equal "hive-eval-report", doc.fetch("schema"),
          "#{kind}: the report must be a valid hive-eval-report on a fresh file"
      end
    end
  end

  def test_cli_fails_loudly_when_existing_report_cannot_be_removed
    skip "root bypasses directory write permissions" if Process.uid.zero?

    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "stale.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      with_fake_bundle do |env, marker|
        File.chmod(0555, dir)
        begin
          _out, err, status = Open3.capture3(env, "bin/hive-eval", "--report", report, "--no-judge")
        ensure
          File.chmod(0700, dir)
        end

        refute status.success?
        assert_match(/Errno::EACCES/, err)
        assert File.exist?(report), "failed cleanup must leave the stale report observable"
        refute File.exist?(marker), "hive-eval must stop after report cleanup fails"

        _out, err, status = Open3.capture3(env, "bin/hive-eval", "--report", report, "--bogus")
        assert_equal 64, status.exitstatus
        assert_match(/invalid option: --bogus/, err)
        assert File.exist?(report), "usage validation must preserve a caller-selected report"
        refute File.exist?(marker), "usage validation must stop before launching eval"
      end
    end
  end

  def test_cli_help_is_read_only_and_preserves_selected_report
    [ "--help", "-h" ].each do |help_flag|
      Dir.mktmpdir("hive-eval-report") do |dir|
        report = File.join(dir, "report.json")
        File.write(report, JSON.dump({ "schema" => "hive-eval-report", "preexisting" => true }))

        out, _err, status = Open3.capture3(
          { "HIVE_EVAL_NO_JUDGE" => "1" },
          "bin/hive-eval", "--report", report, help_flag
        )

        assert status.success?, "#{help_flag} must exit successfully"
        assert_match(%r{Usage: bin/hive-eval}, out, "#{help_flag} must print usage")
        assert File.exist?(report),
          "#{help_flag} is read-only and must not delete the selected report"
      end
    end
  end

  def test_cli_reports_when_bundler_cannot_be_spawned
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "report.json")
      out, err, status = Open3.capture3(
        { "PATH" => "" },
        RbConfig.ruby, "bin/hive-eval", "--no-judge", "--report", report
      )

      assert_equal 127, status.exitstatus
      assert_empty out
      assert_match(/could not launch `bundle exec rake test:eval`/, err)
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
      assert_match(/unexpected argument: definitely-not-a-scenario/, err)
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

  private

  # Run the block with `path` safe to clobber, restoring whatever was there
  # before (or removing the file if it did not exist). Lets a test exercise the
  # hardcoded default report location without leaking into a developer's checkout.
  def preserve_path(path)
    existed = File.exist?(path)
    backup = "#{path}.preserve-#{Process.pid}-#{object_id}"
    FileUtils.cp(path, backup) if existed
    yield
  ensure
    if existed
      FileUtils.cp(backup, path)
    else
      FileUtils.rm_f(path)
    end
    FileUtils.rm_f(backup)
  end

  def fake_report(file:, status: "pass")
    JSON.dump({
      "schema" => "hive-eval-report",
      "schema_version" => 1,
      "scenarios" => [ {
        "scenario_name" => "FakeScenario#test_fake",
        "file" => file,
        "status" => status,
        "failures" => [],
        "assertions" => [],
        "captured_messages" => [],
        "captured_log_events" => []
      } ]
    })
  end

  def with_fake_bundle
    Dir.mktmpdir("hive-eval-fake-bundle") do |dir|
      bin_dir = File.join(dir, "bin")
      marker = File.join(dir, "bundle-called")
      bundle = File.join(bin_dir, "bundle")
      FileUtils.mkdir_p(bin_dir)
      File.write(bundle, <<~RUBY)
        #!/usr/bin/env ruby
        marker = [ ENV["RAKEOPT"].inspect, *ARGV ].join("\\n")
        File.write(ENV.fetch("HIVE_EVAL_FAKE_BUNDLE_MARKER"), marker)
        if ENV["HIVE_EVAL_FAKE_READY"]
          File.write(ENV.fetch("HIVE_EVAL_FAKE_READY"), "ready\\n")
          sleep 0.01 until File.exist?(ENV.fetch("HIVE_EVAL_FAKE_RELEASE"))
        end
        if ENV["HIVE_EVAL_FAKE_REPORT"]
          File.write(ENV.fetch("HIVE_EVAL_REPORT"), ENV.fetch("HIVE_EVAL_FAKE_REPORT"))
        end
        if ENV["HIVE_EVAL_FAKE_INSECURE_PARENT"]
          File.chmod(0o777, File.dirname(File.dirname(ENV.fetch("HIVE_EVAL_REPORT"))))
        end
      RUBY
      FileUtils.chmod("+x", bundle)

      env = {
        "HIVE_EVAL_FAKE_BUNDLE_MARKER" => marker,
        "PATH" => [ bin_dir, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR)
      }
      yield env, marker
    end
  end
end
