require_relative "../../test_helper"
require "fileutils"
require "json"
require "open3"
require "psych"
require "rbconfig"
require "securerandom"
require "json_schemer"
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

  def with_temp_scenario(name, body, catalog: true)
    path = File.join(Hive::E2E::Paths.scenarios_dir, "#{name}.yml")
    coverage_id = "test.#{name}"
    coverage_path = File.join(Hive::E2E::Paths.e2e_root, "coverage.yml")
    original_catalog = File.binread(coverage_path)
    scenario_body = body
    unless body.match?(/^coverage:/)
      scenario_body = "#{body.rstrip}\ncoverage:\n  primary: #{coverage_id}\n  supporting: []\n"
    end
    File.write(path, scenario_body)
    if catalog
      catalog_data = Psych.safe_load(original_catalog, aliases: false)
      catalog_data.fetch("coverage") << {
        "id" => coverage_id,
        "title" => "Synthetic binary contract",
        "description" => "Temporary binary-level scenario used by the focused harness tests.",
        "maturity" => "required",
        "profiles" => [ "release" ],
        "constraints" => { "platforms" => [], "providers" => [] },
        "docs" => [ "wiki/e2e.md" ],
        "code" => [ "test/e2e/scenarios/#{name}.yml" ]
      }
      File.write(coverage_path, Psych.dump(catalog_data))
    end
    yield
  ensure
    File.binwrite(coverage_path, original_catalog) if original_catalog
    FileUtils.rm_f(path) if path
  end

  def create_retention_run(runs_dir, failed: 0, age_days: 1)
    run_dir = File.join(runs_dir, "2026-07-22T10-00-00Z-1234-abcd")
    FileUtils.mkdir_p(run_dir)
    File.write(
      File.join(run_dir, "report.json"),
      JSON.generate("status" => "complete", "summary" => { "failed" => failed })
    )
    old = Time.now - (age_days * 86_400)
    File.utime(old, old, run_dir)
    run_dir
  end

  def with_unexpected_run_failure(kind)
    name = "binary_unexpected_#{Process.pid}_#{SecureRandom.hex(6)}"
    with_temp_scenario(name, <<~YAML) do
      name: #{name}
      steps:
        - kind: write_file
          path: "{sandbox}/created.txt"
          content: ok
    YAML
      Dir.mktmpdir("e2e-unexpected-run") do |scratch|
        runs_dir = File.join(scratch, "runs")
        if kind == :blocked_runs
          File.write(runs_dir, "unchanged blocker")
        else
          path = File.join(Hive::E2E::Paths.scenarios_dir, "#{name}.yml")
          File.unlink(path)
          File.symlink(File.join(scratch, "missing.yml"), path)
        end
        yield(name, runs_dir)
        if kind == :blocked_runs
          assert File.file?(runs_dir)
          assert_equal "unchanged blocker", File.read(runs_dir)
          assert_equal [ "runs" ], Dir.children(scratch), "no partial run or crashed report may be created"
        end
      end
    end
  end

  def assert_error_document(out, kind:, code:, command:)
    payload = parse_single_json_document(out)
    schema = JSONSchemer.schema(JSON.parse(File.read(
      File.join(Hive::E2E::Paths.repo_root, "schemas", "hive-e2e-error.v1.json")
    )))
    assert_empty schema.validate(payload).to_a
    assert_equal kind, payload.fetch("error_kind")
    assert_equal code, payload.fetch("exit_code")
    if command
      assert_equal command, payload["command"]
    else
      assert_nil payload["command"]
    end
    payload
  end

  def assert_run_failure_debug(err, message, kind:, human:)
    lines = err.lines.map(&:chomp)
    assert_equal 1, lines.count("hive-e2e debug: #{message}"), "one debug block must be emitted per attempt"
    assert_equal "hive-e2e: #{message}", lines.shift if human
    assert_equal "hive-e2e debug: #{message}", lines.shift
    refute_empty lines, "debug block must contain the rescued exception's backtrace"
    assert lines.all? { |line| line.match?(/\A  .+:\d+:in /) }, err
    writer_path = Regexp.escape(File.join(__dir__, "runner.rb"))
    atomic_path = Regexp.escape(File.join(Hive::E2E::Paths.lib_dir, "hive", "atomic_file.rb"))
    lines.each do |line|
      refute_match(/\A  #{writer_path}:\d+:in .*\b(?:write_report|write_json)\b/, line)
      refute_match(/\A  #{atomic_path}:\d+:in /, line)
    end

    file, method, operation = if kind == :blocked_runs
                               [ "runner.rb", "run_all", 'FileUtils.mkdir_p(File.join(@run_dir, "scenarios"))' ]
    else
                               [ "scenario_parser.rb", "parse", "File.read(@path)" ]
    end
    source_path = Regexp.escape(File.join(__dir__, file))
    frame = lines.find { |line| line.match?(/\A  #{source_path}:\d+:in .*\b#{method}\b/) }
    refute_nil frame, "expected the original failure operation in #{err}"
    line_number = frame.match(/#{source_path}:(\d+):/)[1].to_i
    source_line = File.readlines(File.join(__dir__, file))[line_number - 1]
    refute_nil source_line, "backtrace line #{line_number} must exist in #{file}"
    assert_includes source_line, operation
  end

  def assert_compatible_error(args, kind:, code:, command:, message:, env: {})
    messages = []
    [ nil, "1" ].product([ false, true ]).each do |debug, json|
      out, err, status = Open3.capture3(
        env.merge("HIVE_E2E_DEBUG" => debug), RbConfig.ruby, hive_e2e, *args, *([ "--json" ] if json)
      )
      assert_equal code, status.exitstatus, "#{args.inspect}: #{out}#{err}"
      if json
        actual = assert_error_document(out, kind: kind, code: code, command: command).fetch("message")
        assert_empty err
      else
        assert_empty out
        assert_match(/\Ahive-e2e: /, err)
        actual = err.lines.first.delete_prefix("hive-e2e: ").chomp
        assert_equal "hive-e2e: #{actual}\n", err
        refute_match(/\.rb:\d+:in /, err)
      end
      if message.is_a?(Regexp)
        assert_match message, actual
      else
        assert_equal message, actual
      end
      messages << actual
    end
    assert_equal 1, messages.uniq.size, "expected errors must stay identical across debug and presentation modes"
  end

  def test_unexpected_run_failures_have_matching_human_and_json_diagnostics
    [ :blocked_runs, :missing_scenario ].each do |kind|
      with_unexpected_run_failure(kind) do |name, runs_dir|
        messages = []
        [ nil, "1" ].product([ false, true ]).each do |debug, json|
          out, err, status = Open3.capture3(
            { "HIVE_E2E_RUNS_DIR" => runs_dir, "HIVE_E2E_DEBUG" => debug },
            hive_e2e, "run", name, *([ "--json" ] if json)
          )
          assert_equal 1, status.exitstatus
          if json
            message = assert_error_document(out, kind: "run_failed", code: 1, command: "run").fetch("message")
          else
            assert_empty out
            assert_match(/\Ahive-e2e: /, err)
            message = err.lines.first.delete_prefix("hive-e2e: ").chomp
          end
          expected_class = kind == :blocked_runs ? /Errno::(?:EEXIST|ENOTDIR)/ : /Errno::ENOENT/
          assert_match(/\A#{expected_class}: .+\z/, message)
          messages << message
          if debug == "1"
            assert_run_failure_debug(err, message, kind: kind, human: !json)
          else
            assert_equal(json ? "" : "hive-e2e: #{message}\n", err)
          end
        end
        refute File.exist?(runs_dir), "catalog parsing must fail before Runner construction" if kind == :missing_scenario
        assert_equal 1, messages.uniq.size, "human and JSON modes must share one canonical message"
      end
    end
  end

  def test_unexpected_run_debug_requires_exact_value_one
    with_unexpected_run_failure(:blocked_runs) do |name, runs_dir|
      [ nil, "", "   ", "0", "true", "yes", "on" ].product([ false, true ]).each do |debug, json|
        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => runs_dir, "HIVE_E2E_DEBUG" => debug },
          hive_e2e, "run", name, *([ "--json" ] if json)
        )
        assert_equal 1, status.exitstatus
        if json
          assert_error_document(out, kind: "run_failed", code: 1, command: "run")
          assert_empty err
        else
          assert_empty out
          assert_match(/\Ahive-e2e: Errno::(?:EEXIST|ENOTDIR): [^\n]+\n\z/, err)
        end
      end
    end
  end

  def test_unexpected_run_debug_emits_only_outer_backtrace_with_existing_cause_and_repeated_frames
    with_unexpected_run_failure(:blocked_runs) do |name, runs_dir|
      Dir.mktmpdir("e2e-exception-cause") do |scratch|
        fixture = File.join(scratch, "failure.rb")
        evidence_path = File.join(scratch, "exception.json")
        # Override the Runner boundary only in the child process; the real
        # binary still owns dispatch, rescue, formatting, and process exit.
        File.write(fixture, <<~RUBY)
          require #{File.join(__dir__, "runner").inspect}
          module CausedRunFailure
            def run_all(**)
              fail_run(3)
            rescue RuntimeError => error
              File.write(#{evidence_path.inspect}, JSON.generate(
                "backtrace" => error.backtrace,
                "cause_backtrace" => error.cause.backtrace,
                "cause_class" => error.cause.class.name,
                "cause_message" => error.cause.message
              ))
              raise
            end

            def fail_run(depth)
              return fail_run(depth - 1) if depth.positive?

              begin
                fail_cause
              rescue ArgumentError
                raise "outer run failure"
              end
            end

            def fail_cause
              raise ArgumentError, "distinct inner failure"
            end
          end
          Hive::E2E::Runner.prepend(CausedRunFailure)
        RUBY

        [ nil, "1" ].product([ false, true ]).each do |debug, json|
          File.delete(evidence_path) if File.exist?(evidence_path)
          out, err, status = Open3.capture3(
            { "HIVE_E2E_RUNS_DIR" => runs_dir, "HIVE_E2E_DEBUG" => debug },
            RbConfig.ruby, "-r", fixture, hive_e2e, "run", name, *([ "--json" ] if json)
          )
          assert_equal 1, status.exitstatus, "#{out}#{err}"
          message = "RuntimeError: outer run failure"
          if json
            assert_equal message, assert_error_document(out, kind: "run_failed", code: 1, command: "run").fetch("message")
          else
            assert_empty out
          end

          assert_path_exists evidence_path, "child did not capture exception evidence: #{out}#{err}"
          evidence = JSON.parse(File.read(evidence_path))
          backtrace = evidence.fetch("backtrace")
          assert_operator backtrace.size, :>, backtrace.uniq.size, "fixture must have legitimate repeated frames"
          assert_equal "ArgumentError", evidence.fetch("cause_class")
          assert_equal "distinct inner failure", evidence.fetch("cause_message")
          cause_only_frames = evidence.fetch("cause_backtrace") - backtrace
          refute_empty cause_only_frames, "fixture must have distinct cause frames"

          expected_lines = json ? [] : [ "hive-e2e: #{message}" ]
          if debug == "1"
            expected_lines << "hive-e2e debug: #{message}"
            expected_lines.concat(backtrace.map { |frame| "  #{frame}" })
          end
          assert_equal expected_lines.map { |line| "#{line}\n" }.join, err
          refute_includes err, evidence.fetch("cause_message")
          cause_only_frames.each { |frame| refute_includes err, frame }
        end
      end
    end
  end

  def test_repeated_unexpected_run_failure_keeps_diagnostics_complete_and_fixture_unchanged
    with_unexpected_run_failure(:blocked_runs) do |name, runs_dir|
      messages = 2.times.map do
        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => runs_dir, "HIVE_E2E_DEBUG" => "1" },
          hive_e2e, "run", name, "--json"
        )
        assert_equal 1, status.exitstatus
        message = assert_error_document(out, kind: "run_failed", code: 1, command: "run").fetch("message")
        assert_match(/\AErrno::(?:EEXIST|ENOTDIR): .+\z/, message)
        assert_run_failure_debug(err, message, kind: :blocked_runs, human: false)
        assert File.file?(runs_dir)
        assert_equal "unchanged blocker", File.read(runs_dir)
        assert_equal [ "runs" ], Dir.children(File.dirname(runs_dir)), "no partial run or crashed report may be created"
        message
      end
      assert_equal messages.first, messages.last
    end
  end

  def test_debug_preserves_unknown_coverage_and_mutually_exclusive_selector_errors
    assert_compatible_error(
      [ "run", "--coverage", "definitely-no-coverage" ], kind: "no_scenarios", code: 64, command: "run",
      message: 'unknown coverage ID "definitely-no-coverage"'
    )
    assert_compatible_error(
      [ "run", "--coverage", "runtime.error_envelope", "--profile", "release" ],
      kind: "usage", code: 64, command: "run",
      message: "--profile and --coverage are mutually exclusive and cannot be combined with PATTERN or --filter"
    )
  end

  def test_debug_preserves_outer_thor_usage_error
    Dir.mktmpdir("e2e-clean-usage") do |runs_dir|
      assert_compatible_error(
        [ "clean", "--retain-days" ], kind: "usage", code: 64, command: nil,
        message: "No value provided for option '--retain-days'", env: { "HIVE_E2E_RUNS_DIR" => runs_dir }
      )
    end
  end

  def test_debug_preserves_outer_generic_error_without_run_failure_formatting
    with_unexpected_run_failure(:missing_scenario) do |name, runs_dir|
      assert_compatible_error(
        [ "list" ], kind: "error", code: 1, command: nil,
        message: /\ANo such file or directory[^\n]*#{name}\.yml\z/,
        env: { "HIVE_E2E_RUNS_DIR" => runs_dir }
      )
    end
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

  def test_coverage_json_exact_match_is_schema_valid_and_has_one_safe_command
    out, err, status = Open3.capture3(
      hive_e2e, "coverage", "--match", "workflow.full_pipeline", "--json"
    )

    assert status.success?, err
    payload = parse_single_json_document(out)
    assert_equal "hive-e2e-coverage", payload.fetch("schema")
    assert_equal [ "workflow.full_pipeline" ],
                 payload.fetch("matches").map { |match| match.fetch("id") }
    assert_equal "bin/hive-e2e run --coverage workflow.full_pipeline",
                 payload.dig("matches", 0, "runnable_command")
    schema = JSONSchemer.schema(JSON.parse(File.read(
      File.join(Hive::E2E::Paths.repo_root, "schemas", "hive-e2e-coverage.v1.json")
    )))
    assert_empty schema.validate(payload).to_a
  end

  def test_coverage_substring_order_human_output_and_no_match_contract
    out, err, status = Open3.capture3(hive_e2e, "coverage", "--match", "update", "--json")
    assert status.success?, err
    ids = JSON.parse(out).fetch("matches").map { |match| match.fetch("id") }
    assert_equal ids.sort, ids

    out, err, status = Open3.capture3(
      hive_e2e, "coverage", "--match", "recovery.provider_limit"
    )
    assert status.success?, err
    assert_includes out, "recovery.provider_limit"
    assert_includes out, "bin/hive-e2e run --coverage recovery.provider_limit"

    assert_compatible_error(
      [ "coverage", "--match", "definitely-no-coverage" ],
      kind: "no_scenarios", code: 64, command: "coverage", message: "no coverage matches definitely-no-coverage"
    )
  end

  def test_run_coverage_executes_only_primary_and_writes_selection_companion
    Dir.mktmpdir("e2e-semantic-run") do |runs_dir|
      out, err, status = Open3.capture3(
        { "HIVE_E2E_RUNS_DIR" => runs_dir },
        hive_e2e, "run", "--coverage", "runtime.error_envelope", "--json"
      )

      assert status.success?, err
      report = JSON.parse(out)
      assert_equal [ "run_error_envelope" ],
                   report.fetch("scenario_metadata").map { |row| row.fetch("name") }
      run_dir = Dir[File.join(runs_dir, "*")].first
      selection = JSON.parse(File.read(File.join(run_dir, "selection.json")))
      assert_equal [ "runtime.error_envelope" ], selection.fetch("coverage_ids")
      assert_equal [ "run_error_envelope" ], selection.fetch("scenarios")
    end
  end

  def test_run_pending_or_planned_coverage_has_no_runnable_scenario
    out, err, status = Open3.capture3(
      hive_e2e, "run", "--coverage", "attempt.caller_loss_adoption", "--json"
    )

    assert_equal 64, status.exitstatus
    assert_empty err
    payload = JSON.parse(out)
    assert_equal "no_scenarios", payload.fetch("error_kind")
    assert_match(/no runnable scenario/, payload.fetch("message"))
  end

  def test_unknown_scenario_mapping_fails_before_run_creation
    name = "unknown_coverage_mapping_#{Process.pid}"
    with_temp_scenario(name, <<~YAML, catalog: false) do
      name: #{name}
      coverage:
        primary: test.not_in_catalog
        supporting: []
      steps:
        - kind: cli
          args: [version]
    YAML
      Dir.mktmpdir("e2e-preflight-runs") do |runs_dir|
        out, err, status = Open3.capture3(
          { "HIVE_E2E_RUNS_DIR" => runs_dir },
          hive_e2e, "run", name, "--json"
        )

        assert_equal 78, status.exitstatus
        assert_empty err
        assert_match(/unknown coverage ID/, JSON.parse(out).fetch("message"))
        assert_empty Dir.children(runs_dir), "catalog preflight must not create a run directory"
      end
    end
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
      assert_equal 3, metadata.count { |entry| entry["pending"] == true }
      assert_equal 6, metadata.map { |entry| entry["incident_id"] }.uniq.size
      assert_equal 3, report.dig("summary", "total")
      assert_equal 3, report.dig("summary", "passed")
      assert_equal %w[
        incident_plan_only_dependency_gate
        incident_provider_limit_retry
        incident_repository_routing
      ],
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

      reports = Dir[File.join(runs_dir, "*", "report.json")].map { |path| File.read(path) }
      assert status.success?, ([ err, out ] + reports).join("\n")
      assert_match(/selected 6, executed 3, pending 3, passed 3, failed 0/, out)
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

  def test_clean_accepts_legacy_retention_environment_with_deprecation_warning
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      create_retention_run(tmp_runs_dir)

      out, err, status = Open3.capture3(
        {
          "HIVE_E2E_RUNS_DIR" => tmp_runs_dir,
          "HIVE_E2E_RUNS_RETAIN_DAYS" => nil,
          "RUNS_RETAIN_DAYS" => "2"
        },
        hive_e2e, "clean", "--json"
      )

      assert status.success?, err
      payload = parse_single_json_document(out)
      assert_equal 0, payload.fetch("deleted")
      assert_equal 1, payload.fetch("kept")
      assert_equal 2, payload.dig("kept_runs", 0, "retain_days")
      assert_match(/RUNS_RETAIN_DAYS is deprecated; use HIVE_E2E_RUNS_RETAIN_DAYS instead/, err)
    end
  end

  def test_clean_prefers_namespaced_retention_environment_when_both_are_set
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      create_retention_run(tmp_runs_dir)

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
      refute_match(/deprecated/, err)
    end
  end

  def test_clean_prefers_namespaced_failed_retention_environment_when_legacy_conflicts
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      create_retention_run(tmp_runs_dir, failed: 1)

      out, err, status = Open3.capture3(
        {
          "HIVE_E2E_RUNS_DIR" => tmp_runs_dir,
          "RUNS_RETAIN_FAILED_DAYS" => "0",
          "HIVE_E2E_RUNS_RETAIN_FAILED_DAYS" => "2"
        },
        hive_e2e, "clean", "--json", "--dry-run"
      )

      assert status.success?, err
      payload = parse_single_json_document(out)
      assert_equal 0, payload.fetch("deleted")
      assert_equal 1, payload.fetch("kept")
      assert_equal 2, payload.dig("kept_runs", 0, "retain_days")
      refute_match(/deprecated/, err)
    end
  end

  def test_clean_dry_run_json_reports_legacy_retention_days_without_deleting
    Dir.mktmpdir("e2e-clean-test") do |tmp_runs_dir|
      run_dir = create_retention_run(tmp_runs_dir)

      out, err, status = Open3.capture3(
        {
          "HIVE_E2E_RUNS_DIR" => tmp_runs_dir,
          "HIVE_E2E_RUNS_RETAIN_DAYS" => nil,
          "RUNS_RETAIN_DAYS" => "0"
        },
        hive_e2e, "clean", "--json", "--dry-run"
      )

      assert status.success?, err
      assert_equal 1, out.scan(/^\{/).count
      payload = parse_single_json_document(out)
      assert_equal true, payload.fetch("dry_run")
      assert_equal 1, payload.fetch("deleted")
      assert_equal 0, payload.fetch("kept")
      assert_equal "would_delete", payload.dig("deleted_runs", 0, "reason")
      assert_equal 0, payload.dig("deleted_runs", 0, "retain_days")
      assert_path_exists run_dir
      assert_match(/RUNS_RETAIN_DAYS is deprecated; use HIVE_E2E_RUNS_RETAIN_DAYS instead/, err)
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

  def test_replay_missing_repro_preserves_human_and_json_errors_with_debug
    Dir.mktmpdir("e2e-replay-test") do |runs_dir|
      script = File.join(runs_dir, "missing-run", "scenarios", "missing-scenario", "repro.sh")
      assert_compatible_error(
        [ "replay", "missing-run", "missing-scenario" ], kind: "missing_repro", code: 78, command: "replay",
        message: "Run #missing-run scenario missing-scenario has no repro.sh; " \
                 "the run may have completed successfully (#{script})",
        env: { "HIVE_E2E_RUNS_DIR" => runs_dir }
      )
      assert_empty Dir.children(runs_dir)
    end
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
        [ false, true ].each do |json|
          out, err, status = Open3.capture3(
            { "HIVE_E2E_RUNS_DIR" => runs_dir, "HIVE_E2E_DEBUG" => "1" },
            hive_e2e, "run", failing, *([ "--json" ] if json)
          )
          assert_equal 1, status.exitstatus, err
          assert_empty err
          refute_includes out, "run_failed"
          refute_match(/hive-e2e debug:|\.rb:\d+:in /, out)
          if json
            report = parse_single_json_document(out)
            assert_equal "hive-e2e-report", report.fetch("schema")
            assert_equal "complete", report.fetch("status")
            assert_equal 1, report.dig("summary", "failed")
            assert_equal "failed", report.fetch("scenarios").first.fetch("status")
          else
            assert_equal "selected 1, executed 1, pending 0, passed 0, failed 1\n", out
          end
        end
      end
    end
  end

  def test_replay_non_executable_repro_preserves_human_and_json_errors_with_debug
    Dir.mktmpdir("e2e-replay-test") do |runs_dir|
      script = File.join(runs_dir, "run-1", "scenarios", "scenario-1", "repro.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o644, script)
      assert_compatible_error(
        [ "replay", "run-1", "scenario-1" ], kind: "unusable_repro", code: 78, command: "replay",
        message: "Run #run-1 scenario scenario-1 repro.sh is not executable (#{script})",
        env: { "HIVE_E2E_RUNS_DIR" => runs_dir }
      )
      assert_equal "#!/usr/bin/env bash\nexit 0\n", File.read(script)
      refute File.executable?(script)
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

  def test_run_no_match_preserves_human_and_json_errors_with_debug
    assert_compatible_error(
      [ "run", "definitely-no-scenario" ], kind: "no_scenarios", code: 64, command: "run",
      message: "no scenarios match definitely-no-scenario"
    )
  end

  def test_malformed_scenario_is_preflight_error_in_human_and_json_modes_with_debug
    name = "malformed_scenario_#{Process.pid}"
    with_temp_scenario(name, "name: #{name}\nsteps:\n  - kind: [\n") do
      [ [ "list" ], [ "run", name ] ].each do |args|
        path = File.join(Hive::E2E::Paths.scenarios_dir, "#{name}.yml")
        assert_compatible_error(
          args, kind: "preflight", code: 78, command: args.first,
          message: /\A#{Regexp.escape(path)}:\d+: /
        )
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
        assert_compatible_error(
          [ "run", name ], kind: "preflight", code: 78, command: "run",
          message: /\Atmux not found\. Install with: /, env: { "PATH" => empty_path }
        )
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

  def test_clean_rejects_invalid_retention_values_with_and_without_debug
    Dir.mktmpdir("e2e-clean-test") do |runs_dir|
      assert_compatible_error(
        [ "clean", "--retain-days", "-1" ], kind: "usage", code: 64, command: "clean",
        message: "retain_days must be >= 0", env: { "HIVE_E2E_RUNS_DIR" => runs_dir }
      )
      assert_empty Dir.children(runs_dir)
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
