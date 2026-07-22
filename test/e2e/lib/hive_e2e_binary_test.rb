require_relative "../../test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "paths"

class E2EBinaryTest < Minitest::Test
  def hive_e2e
    File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e")
  end

  def parse_single_json_document(out)
    JSON.parse(out)
  rescue JSON::ParserError => e
    flunk "expected exactly one parseable JSON document on stdout: #{e.message}"
  end

  def with_temp_scenario(name, body)
    path = File.join(Hive::E2E::Paths.scenarios_dir, "#{name}.yml")
    File.write(path, body)
    yield
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_list_json_emits_parseable_envelope_with_schema_version_1
    out, err, status = Open3.capture3(hive_e2e, "list", "--json")
    assert status.success?, "bin/hive-e2e list --json should exit 0, stderr was: #{err}"
    assert_equal 1, out.scan(/^\{/).count,
                 "bin/hive-e2e list --json should emit exactly one JSON document"

    payload = parse_single_json_document(out)
    assert_equal "hive-e2e-scenarios", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_kind_of Array, payload["scenarios"], "envelope should carry a scenarios array"
    assert payload["scenarios"].any?, "at least one scenario should be inventoried"
    sample = payload["scenarios"].first
    %w[name tags description path steps_count incident_id sibling_task_id pending].each do |key|
      assert sample.key?(key), "scenario summary should expose #{key.inspect}"
    end

    incident = payload.fetch("scenarios").find { |entry| entry["incident_id"] }
    assert incident
    assert_match(/\A#\d+\z/, incident.fetch("sibling_task_id"))
    assert_includes [ true, false ], incident.fetch("pending")
  end

  def test_incident_inventory_reports_enabled_results_and_pending_metadata
    Dir.mktmpdir("e2e-incident-report") do |runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => runs_dir },
        hive_e2e, "run", "--filter", "incident-regression", "--json"
      )

      assert status.success?, "pending incident inventory should exit 0, stderr was: #{err}"
      report = parse_single_json_document(out)
      metadata = report.fetch("scenario_metadata")

      assert_equal 6, metadata.size
      assert_equal 4, metadata.count { |entry| entry["pending"] == true }
      assert_equal 6, metadata.map { |entry| entry["incident_id"] }.uniq.size
      assert_equal 2, report.dig("summary", "total")
      assert_equal 2, report.dig("summary", "passed")
      assert_equal %w[incident_plan_only_dependency_gate incident_repository_routing],
                   report.fetch("scenarios").map { |scenario| scenario.fetch("name") }.sort
      assert_equal "complete", report.fetch("status")
    end
  end

  def test_human_incident_run_reports_executed_and_pending_counts
    Dir.mktmpdir("e2e-incident-report") do |runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => runs_dir },
        hive_e2e, "run", "--filter", "incident-regression"
      )

      assert status.success?, err
      assert_match(/selected 6, executed 2, pending 4, passed 2, failed 0/, out)
    end
  end

  def test_pending_only_human_run_is_green_but_not_silent
    Dir.mktmpdir("e2e-incident-report") do |runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => runs_dir },
        hive_e2e, "run", "incident_attempt_adoption_after_caller_loss"
      )

      assert status.success?, err
      assert_match(/selected 1, executed 0, pending 1, passed 0, failed 0/, out)
    end
  end

  def test_leading_json_list_dispatches_to_list
    out, err, status = Open3.capture3(hive_e2e, "--json", "list")
    assert status.success?, "bin/hive-e2e --json list should exit 0, stderr was: #{err}"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-scenarios", payload["schema"]
  end

  def test_leading_json_true_list_dispatches_to_list
    out, err, status = Open3.capture3(hive_e2e, "--json=true", "list")
    assert status.success?, "bin/hive-e2e --json=true list should exit 0, stderr was: #{err}"

    assert_includes out, '"schema": "hive-e2e-scenarios"'
    refute_includes out, '"error_kind": "no_scenarios"'
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
      assert_equal 1, out.scan(/^\{/).count,
                   "bin/hive-e2e clean --json should emit exactly one JSON document"

      payload = parse_single_json_document(out)
      assert_equal "hive-e2e-clean", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_kind_of Integer, payload["deleted"]
      assert_kind_of Integer, payload["kept"]
    end
  end

  def test_clean_retention_environment_is_hive_e2e_namespaced
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      run_dir = File.join(tmp_runs_dir, "2026-07-22T10-00-00Z-1234-abcd")
      FileUtils.mkdir_p(run_dir)
      File.write(
        File.join(run_dir, "report.json"),
        JSON.generate("status" => "complete", "summary" => { "failed" => 0 })
      )
      old = Time.now - 86_400
      File.utime(old, old, run_dir)

      out, err, status = Open3.capture3(
        {
          "HIVE_E2E_RUNS_DIR" => tmp_runs_dir,
          "RUNS_RETAIN_DAYS" => "0",
          "HIVE_E2E_RUNS_RETAIN_DAYS" => "2"
        },
        hive_e2e, "clean", "--json", "--dry-run"
      )

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal 0, payload.fetch("deleted")
      assert_equal 1, payload.fetch("kept")
      assert_equal 2, payload.dig("kept_runs", 0, "retain_days")
    end
  end

  def test_leading_json_clean_dispatches_to_clean
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "--json", "clean"
      )
      assert status.success?, "bin/hive-e2e --json clean should exit 0, stderr was: #{err}"

      payload = JSON.parse(out)
      assert_equal "hive-e2e-clean", payload["schema"]
    end
  end

  # Unknown command + --json must emit a hive-e2e-error envelope on stdout
  # (not Thor's prose on stderr) so wrappers parsing JSON can detect bad
  # invocations programmatically. Verified manually: previously printed
  # "Could not find command \"no-such\"." to stderr with exit 1.
  def test_unknown_command_with_json_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "no-such", "--json")
    assert_equal 64, status.exitstatus
    assert_empty err, "human prose must not leak to stderr when --json is set"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
    assert_match(/no-such/, payload["message"])
  end

  # Missing required positional args + --json must also emit an envelope
  # rather than Thor's "ERROR: ... was called with no arguments" prose.
  def test_missing_required_args_with_json_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "replay", "--json")
    assert_equal 64, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
  end

  def test_version_short_flag_prints_hive_version
    out, _err, status = Open3.capture3(hive_e2e, "--version")
    assert status.success?
    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_leading_json_top_level_version_prints_hive_version
    %w[--version -v].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "--json", flag)
      assert status.success?, "bin/hive-e2e --json #{flag} should exit 0, stderr was: #{err}"
      assert_equal "#{Hive::VERSION}\n", out
    end
  end

  def test_version_subcommand_json_emits_one_versioned_document
    [ %w[version --json], %w[--json version] ].each do |argv|
      out, err, status = Open3.capture3(hive_e2e, *argv)

      assert status.success?, "#{argv.inspect}: #{err}"
      assert_empty err
      payload = parse_single_json_document(out)
      assert_equal "hive-e2e-version", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal Hive::VERSION, payload["version"]
    end
  end

  # Thor's default for unknown commands is to print a deprecation warning
  # and exit 0; we override `exit_on_failure?` to true so wrappers / CI
  # see a non-zero status instead. Pin the contract here.
  def test_unknown_command_exits_usage_code
    _out, err, status = Open3.capture3(hive_e2e, "no-such-command")
    assert_equal 64, status.exitstatus
    assert_match(/hive-e2e:/, err, "human mode should print a prose error to stderr")
  end

  def test_missing_required_args_exits_usage_code
    _out, err, status = Open3.capture3(hive_e2e, "replay")
    assert_equal 64, status.exitstatus
    assert_match(/hive-e2e:/, err, "human mode should print a prose error to stderr")
  end

  def test_run_help_after_subcommand_shows_usage
    out, err, status = Open3.capture3(hive_e2e, "run", "--help")
    assert status.success?, "bin/hive-e2e run --help should exit 0, stderr was: #{err}"
    assert_includes out, "Run e2e scenarios"
    refute_includes err, "no scenarios match"
  end

  def test_pattern_help_shows_run_help
    out, err, status = Open3.capture3(hive_e2e, "some-pattern", "--help")

    assert status.success?, err
    assert_includes out, "hive-e2e run [PATTERN]"
    assert_includes out, "Run e2e scenarios"
  end

  def test_leading_json_top_level_help_shows_usage
    %w[--help -h].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "--json", flag)
      assert status.success?, "bin/hive-e2e --json #{flag} should exit 0, stderr was: #{err}"
      assert_includes out, "Commands:"
      refute_includes out, "hive-e2e-error"
      refute_includes err, "no scenarios match"
    end
  end

  # A leading --json followed by a help flag and a recognized command
  # (`--json --help run`, `--json -h run`) requests that command's help, exactly
  # like `--help run`. Help is human prose, so the leading --json is dropped and
  # Thor renders the command's usage with exit 0 — it must not regress into a
  # run_scenarios usage error (exit 64) as it did when --json was restored ahead
  # of the help flag.
  def test_leading_json_help_with_command_shows_command_help
    %w[--help -h].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "--json", flag, "run")
      assert status.success?, "bin/hive-e2e --json #{flag} run should exit 0, stderr was: #{err}"
      assert_includes out, "hive-e2e run [PATTERN]"
      assert_includes out, "Run e2e scenarios"
      refute_includes out, "hive-e2e-error"
      refute_includes err, "no scenarios match"
    end
  end

  # A leading --json followed by a top-level flag plus a trailing token
  # (e.g. `--json --help missing`) must still honor the JSON-envelope
  # contract. Normalization shifts the leading --json out of ARGV and returns
  # early on the top-level flag without restoring it, so the rescue path must
  # consult the caller's original JSON request rather than the mutated ARGV.
  def test_leading_json_help_with_trailing_token_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "--json", "--help", "missing")
    assert_equal 64, status.exitstatus
    assert_empty err, "human prose must not leak to stderr when --json precedes --help"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
  end

  def test_leading_json_version_with_trailing_token_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "--json", "--version", "extra")
    assert_equal 64, status.exitstatus
    assert_empty err, "human prose must not leak to stderr when --json precedes --version"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
  end

  # A leading --json followed by a top-level flag AND a recognized option
  # (e.g. `--json --version --filter tui`) does not raise a Thor error: Thor
  # consumes the flag as the run pattern and dispatches into run_scenarios,
  # whose body reads options[:json]. The stripped --json must be restored so
  # the command honors the JSON contract instead of printing prose on stderr;
  # the outer rescue's json_mode snapshot cannot cover this dispatch path.
  def test_leading_json_top_level_flag_then_option_emits_envelope_on_stdout
    %w[--version -v --help -h].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "--json", flag, "--filter", "tui")
      assert_equal 64, status.exitstatus, "#{flag}: usage error must exit 64"
      assert_empty err, "#{flag}: human prose must not leak to stderr when --json leads"

      payload = JSON.parse(out)
      assert_equal "hive-e2e-error", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "no_scenarios", payload["error_kind"]
      assert_equal 64, payload["exit_code"]
      assert_match(/no scenarios match #{Regexp.escape(flag)}/, payload["message"])
    end
  end

  def test_run_help_after_option_value_shows_usage
    out, err, status = Open3.capture3(hive_e2e, "run", "--filter", "tui", "--help")
    assert status.success?, "bin/hive-e2e run --filter tui --help should exit 0, stderr was: #{err}"
    assert_includes out, "Run e2e scenarios"
    refute_includes err, "no scenarios match"
  end

  def test_run_treats_help_after_delimiter_as_literal_pattern
    out, err, status = Open3.capture3(hive_e2e, "run", "--", "--help")

    assert_equal 64, status.exitstatus
    assert_empty out
    assert_match(/no scenarios match --help/, err)
    refute_match(/Usage:/, err)
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
    assert_equal "replay", payload["command"]
  end

  def test_run_error_envelope_names_run_command
    out, err, status = Open3.capture3(hive_e2e, "run", "definitely-no-scenario", "--json")

    assert_equal 64, status.exitstatus
    assert_empty err
    assert_equal "run", JSON.parse(out)["command"]
  end

  def test_binary_run_contract_covers_success_and_scenario_failure
    Dir.mktmpdir("e2e-binary-contract-runs") do |runs_dir|
      passing = "binary_contract_pass_#{Process.pid}"
      with_temp_scenario(passing, <<~YAML) do
        name: #{passing}
        steps:
          - kind: write_file
            path: "{sandbox}/created.txt"
            content: ok
      YAML
        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => runs_dir }, hive_e2e, "run", passing, "--json"
        )
        assert status.success?, err
        assert_equal "complete", JSON.parse(out)["status"]
      end

      failing = "binary_contract_fail_#{Process.pid}"
      with_temp_scenario(failing, <<~YAML) do
        name: #{failing}
        steps:
          - kind: state_assert
            path: "{sandbox}/missing.txt"
      YAML
        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => runs_dir }, hive_e2e, "run", failing, "--json"
        )
        assert_equal 1, status.exitstatus, err
        report = JSON.parse(out)
        assert_equal 1, report.dig("summary", "failed")
        assert_equal "failed", report.fetch("scenarios").first.fetch("status")
      end
    end
  end

  def test_replay_non_executable_repro_emits_json_artifact_error_when_requested
    Dir.mktmpdir("e2e-replay-test") do |tmp_runs_dir|
      script = File.join(tmp_runs_dir, "run-1", "scenarios", "scenario-1", "repro.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o644, script)

      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "replay", "--json", "run-1", "scenario-1"
      )

      assert_equal 78, status.exitstatus
      assert_empty err

      payload = JSON.parse(out)
      assert_equal "hive-e2e-error", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unusable_repro", payload["error_kind"]
      assert_equal 78, payload["exit_code"]
      assert_match(/not executable/, payload["message"])
    end
  end

  def test_replay_executes_executable_repro_and_preserves_argv0
    skip "/bin/bash is required to verify argv0 handoff" unless File.executable?("/bin/bash")

    Dir.mktmpdir("e2e-replay-test") do |tmp_runs_dir|
      script = File.join(tmp_runs_dir, "run-1", "scenarios", "scenario-1", "repro.sh")
      FileUtils.mkdir_p(File.dirname(script))
      FileUtils.cp("/bin/bash", script)
      File.chmod(0o755, script)

      hook = File.join(tmp_runs_dir, "argv0-hook")
      File.write(hook, <<~BASH)
        printf 'replay ok\\n'
        printf 'argv0=%s\\n' "$0"
        exit 23
      BASH

      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir, "BASH_ENV" => hook },
        hive_e2e, "replay", "run-1", "scenario-1"
      )

      assert_equal 23, status.exitstatus
      assert_empty err
      assert_equal "replay ok\nargv0=repro.sh\n", out
    end
  end

  def test_replay_symlinked_repro_emits_json_artifact_error_when_requested
    Dir.mktmpdir("e2e-replay-test") do |tmp_runs_dir|
      target = File.join(tmp_runs_dir, "outside-repro.sh")
      File.write(target, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o755, target)

      script = File.join(tmp_runs_dir, "run-1", "scenarios", "scenario-1", "repro.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.symlink(target, script)

      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "replay", "--json", "run-1", "scenario-1"
      )

      assert_equal 78, status.exitstatus
      assert_empty err

      payload = JSON.parse(out)
      assert_equal "hive-e2e-error", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unusable_repro", payload["error_kind"]
      assert_equal 78, payload["exit_code"]
      assert_match(/not executable/, payload["message"])
    end
  end

  def test_replay_symlinked_scenario_dir_emits_json_artifact_error_when_requested
    Dir.mktmpdir("e2e-replay-test") do |tmp_runs_dir|
      outside_scenario = File.join(tmp_runs_dir, "outside-scenario")
      script = File.join(outside_scenario, "repro.sh")
      FileUtils.mkdir_p(outside_scenario)
      File.write(script, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o755, script)

      scenario_root = File.join(tmp_runs_dir, "run-1", "scenarios")
      FileUtils.mkdir_p(scenario_root)
      File.symlink(outside_scenario, File.join(scenario_root, "scenario-1"))

      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "replay", "--json", "run-1", "scenario-1"
      )

      assert_equal 78, status.exitstatus
      assert_empty err

      payload = JSON.parse(out)
      assert_equal "hive-e2e-error", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unusable_repro", payload["error_kind"]
      assert_equal 78, payload["exit_code"]
      assert_match(/not executable/, payload["message"])
    end
  end

  def test_replay_symlinked_runs_root_emits_json_artifact_error_when_requested
    Dir.mktmpdir("e2e-replay-target") do |target_runs_dir|
      Dir.mktmpdir("e2e-replay-link-parent") do |link_parent|
        runs_link = File.join(link_parent, "runs")
        File.symlink(target_runs_dir, runs_link)

        script = File.join(target_runs_dir, "run-1", "scenarios", "scenario-1", "repro.sh")
        FileUtils.mkdir_p(File.dirname(script))
        File.write(script, "#!/usr/bin/env bash\nexit 42\n")
        File.chmod(0o755, script)

        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => runs_link },
          hive_e2e, "replay", "--json", "run-1", "scenario-1"
        )

        assert_equal 78, status.exitstatus
        assert_empty err

        payload = JSON.parse(out)
        assert_equal "hive-e2e-error", payload["schema"]
        assert_equal false, payload["ok"]
        assert_equal "unusable_repro", payload["error_kind"]
        assert_equal 78, payload["exit_code"]
        assert_match(/not executable/, payload["message"])
      end
    end
  end

  def test_replay_dangling_symlinked_repro_emits_unusable_not_missing_when_requested
    Dir.mktmpdir("e2e-replay-test") do |tmp_runs_dir|
      target = File.join(tmp_runs_dir, "deleted-repro.sh")

      script = File.join(tmp_runs_dir, "run-1", "scenarios", "scenario-1", "repro.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.symlink(target, script)
      refute File.exist?(target), "symlink target must be absent so the link dangles"

      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "replay", "--json", "run-1", "scenario-1"
      )

      assert_equal 78, status.exitstatus
      assert_empty err

      payload = JSON.parse(out)
      assert_equal "hive-e2e-error", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unusable_repro", payload["error_kind"],
                   "a dangling symlink is a present-but-unusable repro entry, not a missing one"
      assert_equal 78, payload["exit_code"]
      assert_match(/not executable/, payload["message"])
    end
  end

  def test_leading_json_replay_dispatches_to_replay
    out, err, status = Open3.capture3(hive_e2e, "--json", "replay", "missing-run", "missing-scenario")
    assert_equal 78, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal "missing_repro", payload["error_kind"]
  end

  def test_leading_json_unknown_token_still_uses_default_run_pattern
    out, err, status = Open3.capture3(hive_e2e, "--json", "definitely-no-scenario")
    assert_equal 64, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "no_scenarios", payload["error_kind"]
    assert_match(/no scenarios match definitely-no-scenario/, payload["message"])
  end

  def test_leading_unsupported_json_assignments_are_rejected_before_default_run
    %w[--json=1 --json=yes].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, flag, "list")
      value = flag.split("=", 2).last

      assert_equal 64, status.exitstatus, "#{flag}: malformed JSON flag should be a usage error"
      assert_empty out, "#{flag}: unsupported JSON assignments must not request JSON mode"
      assert_match(/invalid boolean value for --json/, err)
      refute_match(/no scenarios match #{Regexp.escape(value)}/, err)
    end
  end

  def test_run_treats_unsupported_json_assignment_after_delimiter_as_literal_pattern
    out, err, status = Open3.capture3(hive_e2e, "run", "--", "--json=bogus")

    assert_equal 64, status.exitstatus
    assert_empty out
    assert_match(/no scenarios match --json=bogus/, err)
    refute_match(/invalid boolean value for --json/, err)
  end

  def test_run_no_match_emits_json_error_when_requested
    out, err, status = Open3.capture3(hive_e2e, "run", "definitely-no-scenario", "--json")
    assert_equal 64, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal "no_scenarios", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
    assert_match(/no scenarios match definitely-no-scenario/, payload["message"])
  end

  def test_malformed_scenario_is_preflight_error_in_json_mode
    name = "malformed_scenario_#{Process.pid}"
    with_temp_scenario(name, "name: #{name}\nsteps:\n  - kind: [\n") do
      [ [ "list" ], [ "run", name ] ].each do |args|
        out, err, status = Open3.capture3(hive_e2e, *args, "--json")

        assert_equal 78, status.exitstatus, "#{args.first}: malformed scenario config must exit 78"
        assert_empty err
        payload = JSON.parse(out)
        assert_equal "hive-e2e-error", payload["schema"]
        assert_equal "preflight", payload["error_kind"]
        assert_equal 78, payload["exit_code"]
        assert_match(/#{name}\.yml/, payload["message"])
      end
    end
  end

  def test_malformed_scenario_is_preflight_error_in_human_mode
    name = "malformed_scenario_#{Process.pid}"
    with_temp_scenario(name, "name: #{name}\nsteps:\n  - kind: [\n") do
      [ [ "list" ], [ "run", name ] ].each do |args|
        out, err, status = Open3.capture3(hive_e2e, *args)

        assert_equal 78, status.exitstatus, "#{args.first}: malformed scenario config must exit 78"
        assert_empty out
        assert_match(/hive-e2e: .*#{name}\.yml/, err)
      end
    end
  end

  def test_malformed_script_gh_contract_is_preflight_error
    name = "malformed_gh_scenario_#{Process.pid}"
    with_temp_scenario(name, <<~YAML) do
      name: #{name}
      steps:
        - kind: script_gh
          interactions:
            - args: auth-status
    YAML
      out, err, status = Open3.capture3(hive_e2e, "list", "--json")

      assert_equal 78, status.exitstatus
      assert_empty err
      payload = JSON.parse(out)
      assert_equal "preflight", payload["error_kind"]
      assert_match(/args must be an array of strings/, payload["message"])
    end
  end

  def test_tui_refute_only_scenario_preflights_missing_tmux
    name = "tui_refute_preflight_#{Process.pid}"
    with_temp_scenario(name, <<~YAML) do
      name: #{name}
      description: patrol regression for tui_refute tmux preflight
      tags: [patrol]
      steps:
        - kind: tui_refute
          anchor: "not present"
    YAML
      Dir.mktmpdir("missing-tmux") do |empty_path|
        out, err, status = Open3.capture3(
          { "PATH" => empty_path },
          RbConfig.ruby, hive_e2e, "run", name, "--json"
        )

        assert_equal 78, status.exitstatus
        assert_empty err
        payload = JSON.parse(out)
        assert_equal "preflight", payload["error_kind"]
        assert_match(/tmux not found/, payload["message"])
      end
    end
  end

  def test_replay_rejects_traversal_components
    out, err, status = Open3.capture3(hive_e2e, "replay", "--json", "../escape", "scenario")
    assert_equal 64, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "usage", payload["error_kind"]
    assert_match(/run_id must be a safe basename/, payload["message"])
  end

  def test_run_invalid_byte_pattern_emits_usage_error_in_c_locale
    out, err, status = Open3.capture3({ "LC_ALL" => "C" }, hive_e2e, "run", "--json", "bad\xFF".b)
    assert_equal 64, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
    assert_match(/invalid byte sequence/, payload["message"])
  end

  def test_clean_rejects_invalid_retention_values
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "clean", "--json", "--retain-days", "-1"
      )
      assert_equal 64, status.exitstatus
      assert_empty err

      payload = JSON.parse(out)
      assert_equal "usage", payload["error_kind"]
      assert_match(/retain_days must be >= 0/, payload["message"])
    end
  end

  def test_clean_rejects_bare_retention_options_before_cleanup
    [ "--retain-days", "--retain-failed-days" ].product([ [], [ "--json" ], [ "--dry-run" ] ]).each do |flag, suffix|
      Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
        run_dir = File.join(tmp_runs_dir, "2026-04-30T12-00-00Z-1234-abcd")
        FileUtils.mkdir_p(run_dir)
        old_time = Time.now - (30 * 86_400)
        File.utime(old_time, old_time, run_dir)

        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
          hive_e2e, "clean", flag, *suffix
        )

        assert_equal 64, status.exitstatus, "#{([ flag ] + suffix).inspect}: malformed cleanup must be rejected"
        assert File.exist?(run_dir), "#{([ flag ] + suffix).inspect}: malformed cleanup must not delete artifacts"
        if suffix.include?("--json")
          assert_empty err
          payload = parse_single_json_document(out)
          assert_equal "usage", payload["error_kind"]
          assert_match(/No value provided for option '#{Regexp.escape(flag)}'/, payload["message"])
        else
          assert_empty out
          assert_match(/No value provided for option '#{Regexp.escape(flag)}'/, err)
        end
      end
    end
  end

  def test_clean_json_includes_dry_run_and_audit_arrays
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => tmp_runs_dir },
        hive_e2e, "clean", "--json", "--dry-run"
      )
      assert status.success?, "bin/hive-e2e clean --json --dry-run should exit 0, stderr was: #{err}"
      assert_equal 1, out.scan(/^\{/).count,
                   "bin/hive-e2e clean --json --dry-run should emit exactly one JSON document"

      payload = JSON.parse(out)
      assert_equal true, payload["dry_run"]
      assert_kind_of Array, payload["deleted_runs"]
      assert_kind_of Array, payload["kept_runs"]
    end
  end

  def test_unknown_command_with_json_true_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "no-such", "--json=true")
    assert_equal 64, status.exitstatus
    assert_empty err, "human prose must not leak to stderr when --json=true is set"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
    assert_match(/no-such/, payload["message"])
  end

  def test_unknown_command_with_json_uppercase_true_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "no-such", "--json=TRUE")
    assert_equal 64, status.exitstatus
    assert_empty err, "human prose must not leak to stderr when --json=TRUE is set"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
    assert_match(/no-such/, payload["message"])
  end

  def test_truthy_json_spellings_agree_with_inner_command_on_success_path
    %w[--json --json=true --json=TRUE --json=t --json=T].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "list", flag)
      assert status.success?, "bin/hive-e2e list #{flag} should exit 0, stderr was: #{err}"

      payload = JSON.parse(out)
      assert_equal "hive-e2e-scenarios", payload["schema"],
                   "#{flag}: inner command must emit the JSON envelope the wrapper assumes truthy"
    end
  end

  def test_unknown_command_with_short_truthy_json_emits_envelope_on_stdout
    %w[--json=t --json=T].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "no-such", flag)
      assert_equal 64, status.exitstatus, "#{flag}: usage error must exit 64"
      assert_empty err, "#{flag}: human prose must not leak to stderr"

      payload = JSON.parse(out)
      assert_equal "hive-e2e-error", payload["schema"]
      assert_equal "usage", payload["error_kind"]
      assert_match(/no-such/, payload["message"])
    end
  end

  def test_negative_json_spellings_fall_through_to_prose
    %w[--json=false --json=0 --no-json --json=True].each do |flag|
      out, err, status = Open3.capture3(hive_e2e, "no-such", flag)
      refute_equal 0, status.exitstatus, "#{flag}: unknown command must still exit non-zero"
      refute_includes out, "hive-e2e-error",
                       "#{flag}: must not emit a JSON envelope on stdout when JSON is not requested"
      refute_empty err, "#{flag}: human prose must go to stderr when JSON is not requested"
    end
  end

  def test_usage_error_respects_last_json_boolean_flag
    [
      %w[--json --no-json],
      %w[--json --json=false]
    ].each do |flags|
      out, err, status = Open3.capture3(hive_e2e, "no-such", *flags)

      assert_equal 64, status.exitstatus, "#{flags.join(" ")}: usage error must exit 64"
      assert_empty out, "#{flags.join(" ")}: final false JSON flag must force prose output"
      assert_match(/hive-e2e:/, err)
    end
  end

  def test_usage_error_ignores_json_booleans_after_delimiter
    out, err, status = Open3.capture3(hive_e2e, "run", "--json", "pattern", "--", "--no-json")

    assert_equal 64, status.exitstatus
    assert_equal "hive-e2e-error", JSON.parse(out)["schema"]
    assert_empty err

    out, err, status = Open3.capture3(hive_e2e, "run", "--no-json", "pattern", "--", "--json")

    assert_equal 64, status.exitstatus
    assert_empty out
    assert_match(/hive-e2e:/, err)
  end

  def test_missing_required_args_with_json_true_emits_envelope_on_stdout
    out, err, status = Open3.capture3(hive_e2e, "replay", "--json=true")
    refute_equal 0, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
  end

  def test_unknown_command_exits_non_zero
    _out, _err, status = Open3.capture3(hive_e2e, "no-such-command")
    refute_equal 0, status.exitstatus,
                 "bin/hive-e2e should exit non-zero on unknown commands (got #{status.exitstatus.inspect})"
  end

  def test_leading_json_before_list_emits_parseable_envelope
    out, err, status = Open3.capture3(hive_e2e, "--json", "list")
    assert status.success?, "bin/hive-e2e --json list should exit 0, stderr was: #{err}"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-scenarios", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_kind_of Array, payload["scenarios"]
  end

  def test_leading_json_before_replay_dispatches_replay_usage_path
    out, err, status = Open3.capture3(hive_e2e, "--json", "replay")
    refute_equal 0, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal false, payload["ok"]
    assert_equal "usage", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
  end

  def test_leading_json_before_run_dispatches_run_path
    out, err, status = Open3.capture3(hive_e2e, "--json", "run", "definitely-no-scenario")
    assert_equal 64, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-e2e-error", payload["schema"]
    assert_equal "no_scenarios", payload["error_kind"]
    assert_equal 64, payload["exit_code"]
    assert_match(/no scenarios match definitely-no-scenario/, payload["message"])
  end
end
