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

  def test_cli_requires_report_when_eval_child_exits_successfully
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "missing.json")

      with_fake_bundle do |env, _marker|
        _out, err, status = Open3.capture3(
          env,
          "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
        )

        refute status.success?
        assert_match(/report was not created/, err)
        refute File.exist?(report)
      end
    end
  end

  def test_cli_rejects_invalid_report_when_eval_child_exits_successfully
    invalid_reports = {
      "not json" => /report contains invalid JSON/,
      JSON.generate({ "schema" => "not-hive-eval-report" }) => /does not match the hive-eval-report v1 schema/
    }

    invalid_reports.each do |document, expected_error|
      Dir.mktmpdir("hive-eval-report") do |dir|
        report = File.join(dir, "invalid.json")

        with_fake_bundle(report: document) do |env, _marker|
          _out, err, status = Open3.capture3(
            env,
            "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
          )

          refute status.success?
          assert_match(expected_error, err)
        end
      end
    end
  end

  def test_cli_requires_report_to_cover_requested_scenario
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "wrong-scenario.json")
      wrong_file = File.expand_path("../scenarios/s2_agent_question_test.rb", __dir__)

      with_fake_bundle(report: eval_report(file: wrong_file)) do |env, _marker|
        _out, err, status = Open3.capture3(
          env,
          "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
        )

        refute status.success?
        assert_match(/report scenario coverage mismatch/, err)
      end
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

  def test_cli_invalid_byte_report_value_clears_selected_report
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
        refute File.exist?(report), "usage errors must not leave invalid-byte selected reports behind"
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

  def test_cli_rejects_scenario_value_that_looks_like_option_and_clears_report
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
        refute File.exist?(report), "usage errors must not leave stale eval reports behind"
        refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
      end
    end
  end

  def test_cli_rejects_scenario_consuming_report_flag_and_clears_named_report
    # `--scenario --report <path>` makes --scenario swallow the --report flag
    # itself, leaving <path> a stray positional. parse! strips the consumed
    # --report token from ARGV, so the rescue cleanup must scan the pre-parse
    # ARGV snapshot — not the mutated ARGV — to still recognize and delete the
    # report the user named.
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
        refute File.exist?(report), "usage errors must not leave the named eval report behind"
        refute File.exist?(marker), "hive-eval must reject the usage error before launching rake"
      end
    end
  end

  def test_cli_rejects_unexpected_positional_arguments
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "unexpected.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report, "extra", "bonus"
      )

      refute status.success?
      assert_equal 64, status.exitstatus
      assert_match(/hive-eval: unexpected arguments: extra bonus/, err)
      refute_match(/argument\(s\)/, err)
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

  def test_cli_usage_error_removes_existing_selected_report
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
      refute File.exist?(report), "usage errors must not leave stale eval reports behind"
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

  def eval_report(file:)
    JSON.generate({
      "schema" => "hive-eval-report",
      "schema_version" => 1,
      "generated_at" => "2026-01-01T00:00:00Z",
      "scenarios" => [ {
        "scenario_name" => "FakeScenario#test_fake",
        "file" => file,
        "status" => "pass",
        "failures" => [],
        "assertions" => [],
        "captured_messages" => [],
        "captured_log_events" => [],
        "duration_ms" => 1
      } ]
    })
  end

  def with_fake_bundle(report: nil)
    Dir.mktmpdir("hive-eval-fake-bundle") do |dir|
      bin_dir = File.join(dir, "bin")
      marker = File.join(dir, "bundle-called")
      bundle = File.join(bin_dir, "bundle")
      FileUtils.mkdir_p(bin_dir)
      File.write(bundle, <<~RUBY)
        #!/usr/bin/env ruby
        File.write(ENV.fetch("HIVE_EVAL_FAKE_BUNDLE_MARKER"), ARGV.join("\\n"))
        File.write(ENV.fetch("HIVE_EVAL_REPORT"), ENV.fetch("HIVE_EVAL_FAKE_REPORT")) if ENV.key?("HIVE_EVAL_FAKE_REPORT")
      RUBY
      FileUtils.chmod("+x", bundle)

      env = {
        "HIVE_EVAL_FAKE_BUNDLE_MARKER" => marker,
        "HIVE_EVAL_FAKE_REPORT" => report,
        "PATH" => [ bin_dir, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR)
      }
      yield env, marker
    end
  end
end
