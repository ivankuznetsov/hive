require "test_helper"
require "fileutils"
require "json"
require "open3"

class HiveEvalBinaryTest < Minitest::Test
  def test_rejects_invalid_arguments_before_launching_eval
    with_fake_bundle do |env, marker, dir|
      report = File.join(dir, "report.json")
      cases = [
        [ [ "s1_status", "--report", report ], /unexpected argument: s1_status/, true ],
        [ [ "--scenario", "../s1_status", "--report", report ],
          /scenario basename must not contain path separators/, false ],
        [ [ "--bogus", "--report", report ], /invalid option: --bogus/, true ]
      ]

      cases.each do |argv, error, shows_usage|
        FileUtils.rm_f(marker)
        File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))
        _out, err, status = Open3.capture3(env, "bin/hive-eval", *argv)

        assert_equal 64, status.exitstatus, err
        assert_match error, err
        assert_match %r{Usage: bin/hive-eval}, err if shows_usage
        refute File.exist?(report), "parser errors must not leave stale eval reports behind"
        refute File.exist?(marker), "invalid arguments must be rejected before launching rake"
      end
    end
  end

  def test_scrubs_ambient_test_and_judge_environment
    with_fake_bundle do |env, marker, dir|
      [ [ [], nil ], [ [ "--no-judge" ], "1" ] ].each_with_index do |(flags, expected_no_judge), index|
        report = File.join(dir, "report-#{index}.json")
        File.write(report, JSON.dump({ "stale" => true }))

        _out, err, status = Open3.capture3(
          env.merge("TEST" => "test/unit/config_test.rb", "HIVE_EVAL_NO_JUDGE" => "ambient"),
          "bin/hive-eval", *flags, "--report", report
        )

        assert status.success?, err
        invocation = File.readlines(marker, chomp: true).to_h { |line| line.split("=", 2) }
        assert_equal "exec rake test:eval", invocation.fetch("argv")
        assert_empty invocation.fetch("test")
        if expected_no_judge
          assert_equal expected_no_judge, invocation.fetch("no_judge")
        else
          assert_empty invocation.fetch("no_judge")
        end
        assert_equal "1", invocation.fetch("scenarios_only")
        assert_equal report, invocation.fetch("report")
        refute File.exist?(report), "hive-eval must clear a stale report before launching rake"
      end
    end
  end

  def test_usage_error_removes_selected_report_without_launching_eval
    with_fake_bundle do |env, marker, dir|
      report = File.join(dir, "stale.json")
      File.write(report, JSON.dump({ "schema" => "hive-eval-report", "stale" => true }))

      _out, err, status = Open3.capture3(
        env,
        "bin/hive-eval", "--report", report, "--scenario", "definitely_missing", "--no-judge"
      )

      assert_equal 64, status.exitstatus, err
      assert_match(/scenario not found/, err)
      refute File.exist?(report), "usage errors must not leave stale eval reports behind"
      refute File.exist?(marker), "missing scenarios must be rejected before launching rake"
    end
  end

  def test_help_preserves_selected_report_without_launching_eval
    with_fake_bundle do |env, marker, dir|
      report = File.join(dir, "existing.json")
      contents = JSON.dump({ "schema" => "hive-eval-report", "existing" => true })
      File.write(report, contents)

      out, err, status = Open3.capture3(env, "bin/hive-eval", "--report", report, "--help")

      assert status.success?, err
      assert_match %r{Usage: bin/hive-eval}, out
      assert_equal contents, File.read(report)
      refute File.exist?(marker), "help must not launch rake"
    end
  end

  private

  def with_fake_bundle
    Dir.mktmpdir("hive-eval-fake-bundle") do |dir|
      bin_dir = File.join(dir, "bin")
      marker = File.join(dir, "bundle-called")
      bundle = File.join(bin_dir, "bundle")
      FileUtils.mkdir_p(bin_dir)
      File.write(bundle, <<~'SH')
        #!/bin/sh
        {
          printf 'argv=%s\n' "$*"
          printf 'test=%s\n' "${TEST-}"
          printf 'no_judge=%s\n' "${HIVE_EVAL_NO_JUDGE-}"
          printf 'scenarios_only=%s\n' "${HIVE_EVAL_SCENARIOS_ONLY-}"
          printf 'report=%s\n' "${HIVE_EVAL_REPORT-}"
        } > "$HIVE_EVAL_FAKE_BUNDLE_MARKER"
      SH
      FileUtils.chmod("+x", bundle)

      env = {
        "HIVE_EVAL_FAKE_BUNDLE_MARKER" => marker,
        "PATH" => [ bin_dir, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR)
      }
      yield env, marker, dir
    end
  end
end
