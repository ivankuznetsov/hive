require_relative "../../test_helper"
require "json"
require "open3"
require_relative "paths"

class E2EBinaryTest < Minitest::Test
  def hive_e2e
    File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e")
  end

  def test_list_json_emits_parseable_envelope_with_schema_version_1
    out, err, status = Open3.capture3(hive_e2e, "list", "--json")
    assert status.success?, "bin/hive-e2e list --json should exit 0, stderr was: #{err}"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-scenarios", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_kind_of Array, payload["scenarios"], "envelope should carry a scenarios array"
    assert payload["scenarios"].any?, "at least one scenario should be inventoried"
    sample = payload["scenarios"].first
    %w[name tags description path steps_count].each do |key|
      assert sample.key?(key), "scenario summary should expose #{key.inspect}"
    end
  end

  def test_clean_json_emits_deleted_and_kept_counts
    # Redirect the runs dir to a temp location so the contract test cannot
    # delete real forensic artifacts under test/e2e/runs/. Without this the
    # test is destructive when a developer runs `rake e2e:lib_test` on a
    # repo that holds prior failure runs.
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "clean", "--json"
      )
      assert status.success?, "bin/hive-e2e clean --json should exit 0, stderr was: #{err}"

      payload = JSON.parse(out)
      assert_equal "hive-e2e-clean", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_kind_of Integer, payload["deleted"]
      assert_kind_of Integer, payload["kept"]
    end
  end

  # Unknown command + --json must emit a hive-e2e-error envelope on stdout
  # (not Thor's prose on stderr) so wrappers parsing JSON can detect bad
  # invocations programmatically. Verified manually: previously printed
  # "Could not find command \"no-such\"." to stderr with exit 1.
  def test_unknown_command_with_json_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "no-such", "--json")
    refute_equal 0, status.exitstatus, "exit must be non-zero"
    assert_empty err, "human prose must not leak to stderr when --json is set"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_match(/no-such/, payload["message"])
  end

  # Missing required positional args + --json must also emit an envelope
  # rather than Thor's "ERROR: ... was called with no arguments" prose.
  def test_missing_required_args_with_json_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "replay", "--json")
    refute_equal 0, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
  end

  def test_version_short_flag_prints_hive_version
    out, _err, status = Open3.capture3(hive_e2e, "--version")
    assert status.success?
    assert_equal "#{Hive::VERSION}\n", out
  end

  # Thor's default for unknown commands is to print a deprecation warning
  # and exit 0; we override `exit_on_failure?` to true so wrappers / CI
  # see a non-zero status instead. Pin the contract here.
  def test_unknown_command_exits_non_zero
    _out, _err, status = Open3.capture3(hive_e2e, "no-such-command")
    refute_equal 0, status.exitstatus,
                 "bin/hive-e2e should exit non-zero on unknown commands (got #{status.exitstatus.inspect})"
  end

  def test_run_help_after_subcommand_shows_usage
    out, err, status = Open3.capture3(hive_e2e, "run", "--help")
    assert status.success?, "bin/hive-e2e run --help should exit 0, stderr was: #{err}"
    assert_includes out, "Run e2e scenarios"
    refute_includes err, "no scenarios match"
  end

  def test_replay_missing_repro_emits_json_error_when_requested
    out, err, status = Open3.capture3(hive_e2e, "replay", "--json", "missing-run", "missing-scenario")
    assert_equal 78, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "missing_repro", payload["error_kind"]
    assert_equal 78, payload["exit_code"]
  end

  def test_run_no_match_emits_json_error_when_requested
    out, err, status = Open3.capture3(hive_e2e, "run", "definitely-no-scenario", "--json")
    assert_equal 1, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal "run_failed", payload["error_kind"]
    assert_match(/no scenarios match definitely-no-scenario/, payload["message"])
  end
end
