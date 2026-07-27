require_relative "../../test_helper"
require "json"
require "tmpdir"
require "json_schemer"
require_relative "runner"
require_relative "paths"

class E2ERunnerTest < Minitest::Test
  def with_isolated_dirs
    Dir.mktmpdir("e2e-scenarios") do |scenarios_dir|
      Dir.mktmpdir("e2e-runs") do |runs_dir|
        yield(scenarios_dir, runs_dir)
      end
    end
  end

  def write_scenario(dir, name, body)
    path = File.join(dir, "#{name}.yml")
    File.write(path, body)
    path
  end

  def report_for(runs_dir)
    run_dir = Dir[File.join(runs_dir, "*")].max_by { |d| File.mtime(d) }
    JSON.parse(File.read(File.join(run_dir, "report.json")))
  end

  def test_happy_run_records_status_complete_and_passed_count
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "smoke_pass", <<~YAML)
        name: smoke_pass
        steps:
          - kind: cli
            args: [version]
            expect_exit: 0
      YAML

      runner = Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir)
      runner.run_all

      report = report_for(runs_dir)

      assert_equal "complete", report["status"], "run-level status should be complete on happy path"
      assert_equal 1, report["summary"]["passed"]
      assert_equal 0, report["summary"]["failed"]
      assert_equal "passed", report["scenarios"].first["status"]
    end
  end

  def test_run_all_accepts_preselected_scenarios_without_selecting_again
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "preselected", <<~YAML)
        name: preselected
        steps:
          - kind: cli
            args: [version]
      YAML

      runner = Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir)
      scenarios = runner.select_scenarios
      runner.define_singleton_method(:select_scenarios) { |**| raise "selected twice" }

      report = runner.run_all(scenarios: scenarios)

      assert_equal 1, report.dig("summary", "passed")
    end
  end

  def test_semantic_run_writes_versioned_selection_companion_without_changing_report
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "selected", <<~YAML)
        name: selected
        steps:
          - kind: cli
            args: [version]
      YAML
      selection = {
        "schema" => "hive-e2e-selection",
        "schema_version" => 1,
        "catalog_digest" => "a" * 64,
        "profile" => nil,
        "coverage_ids" => [ "test.selected" ],
        "scenarios" => [ "selected" ],
        "pending" => [],
        "advisory" => [],
        "planned" => [],
        "replay_command" => "bin/hive-e2e run --coverage test.selected"
      }

      report = Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir)
                                .run_all(selection: selection)
      run_dir = Dir[File.join(runs_dir, "*")].first
      written = JSON.parse(File.read(File.join(run_dir, "selection.json")))

      assert_equal selection, written
      schema = JSONSchemer.schema(JSON.parse(File.read(
        Hive::E2E::Schemas.schema_path("hive-e2e-selection")
      )))
      assert_empty schema.validate(written).to_a
      assert_equal "hive-e2e-report", report.fetch("schema")
      refute report.key?("selection")
    end
  end

  def test_duplicate_scenario_names_fail_preflight
    with_isolated_dirs do |scenarios_dir, runs_dir|
      %w[first second].each do |file|
        write_scenario(scenarios_dir, file, <<~YAML)
          name: duplicate_name
          steps:
            - kind: cli
              args: [version]
        YAML
      end

      error = assert_raises(Hive::E2E::ScenarioParser::InvalidScenario) do
        Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).select_scenarios
      end

      assert_includes error.message, "duplicate scenario name"
    end
  end

  def test_failed_step_keeps_run_complete_but_marks_scenario_failed
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "smoke_fail", <<~YAML)
        name: smoke_fail
        steps:
          - kind: cli
            args: [does-not-exist]
            expect_exit: 0
      YAML

      runner = Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir)
      runner.run_all

      report = report_for(runs_dir)

      assert_equal "complete", report["status"], "run completed (the failure was per-scenario, not a runner crash)"
      assert_equal 1, report["summary"]["failed"]
      assert_equal "failed", report["scenarios"].first["status"]
    end
  end

  def test_bootstrap_failure_records_setup_failed
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "bootstrap_fail", <<~YAML)
        name: bootstrap_fail
        steps:
          - kind: cli
            args: [version]
      YAML

      missing_sample = File.join(runs_dir, "no-such-sample-project-#{Process.pid}")
      runner = Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir)

      # Force the bootstrap to fail by stubbing Sandbox.bootstrap once.
      original = Hive::E2E::Sandbox.method(:bootstrap)
      Hive::E2E::Sandbox.singleton_class.define_method(:bootstrap) do |*_args, **_kw|
        sleep 0.03
        raise "bootstrap exploded for #{missing_sample}"
      end
      begin
        runner.run_all
      ensure
        Hive::E2E::Sandbox.singleton_class.define_method(:bootstrap, original)
      end

      report = report_for(runs_dir)

      assert_equal 1, report["summary"]["setup_failed"], "setup_failed scenarios should appear in summary"
      scenario = report["scenarios"].first
      assert_equal "setup_failed", scenario["status"]
      assert_operator scenario["duration_seconds"], :>=, 0.03,
                      "setup failures must include bootstrap time in incident budgets"
      assert_nil scenario["failed_step_index"], "no step index when bootstrap fails before steps run"
      assert_nil scenario["artifacts_dir"], "no artifacts_dir when bootstrap fails before any are written"
    end
  end

  def test_atomic_write_keeps_prior_report_valid_after_kill
    # Atomic write contract: write_report writes to <path>.tmp.<pid> and
    # File.rename(tmp, path) flips it. Even if a kill -9 strikes mid-write,
    # the prior report.json remains parseable. We exercise this by writing
    # an initial "partial" report, then simulating a torn intermediate by
    # leaving the .tmp file behind — the canonical report.json must still
    # parse cleanly because rename is atomic on the same filesystem.
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "atomicity", <<~YAML)
        name: atomicity
        steps:
          - kind: cli
            args: [version]
      YAML

      runner = Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir)
      runner.run_all

      run_dir = Dir[File.join(runs_dir, "*")].first
      canonical = File.join(run_dir, "report.json")

      # Simulate a torn intermediate alongside the canonical file.
      File.write("#{canonical}.tmp.#{Process.pid}", "garbage{not-json")

      assert File.exist?(canonical)
      parsed = JSON.parse(File.read(canonical))

      assert_equal "complete", parsed["status"]
      assert_kind_of Integer, parsed["summary"]["passed"]
    end
  end

  def test_sigint_during_run_writes_crashed_report
    # Spawn a child that runs the runner with one slow scenario, then SIGINT
    # the child and read its emitted report.json. Ensures the signal handler
    # fires, the report flips to "crashed", and the exit code is 130 (the
    # conventional 128 + SIGINT).
    Dir.mktmpdir("e2e-scenarios") do |scenarios_dir|
      Dir.mktmpdir("e2e-runs") do |runs_dir|
        write_scenario(scenarios_dir, "slow_scenario", <<~YAML)
          name: slow_scenario
          steps:
            - kind: seed_state
              stage: 1-inbox
              slug: slow-task
            - kind: write_file
              path: "{sandbox}/slow-step-started"
              content: ready
            - kind: ruby_block
              block: "sleep 60"
        YAML

        script = <<~RUBY
          $LOAD_PATH.unshift(#{File.expand_path('../', __dir__).inspect})
          $LOAD_PATH.unshift(#{Hive::E2E::Paths.lib_dir.inspect})
          require "lib/runner"
          Hive::E2E::Runner.new(scenarios_dir: #{scenarios_dir.inspect}, runs_dir: #{runs_dir.inspect}).run_all
        RUBY

        script_file = File.join(scenarios_dir, "_driver.rb")
        File.write(script_file, script)

        pid = Process.spawn(RbConfig.ruby, script_file, chdir: File.expand_path("..", __dir__))
        # Wait until bootstrap has completed and the intended slow step is
        # active, then SIGINT. Interrupting earlier can catch Open3 reader
        # threads inside bootstrap and produce noisy report_on_exception output.
        deadline = Time.now + 20
        run_dir = nil
        until run_dir && File.exist?(File.join(run_dir, "report.json")) &&
              File.exist?(File.join(run_dir, "slow_scenario", "sandbox", "slow-step-started"))
          run_dir = Dir[File.join(runs_dir, "*")].first
          break if Time.now >= deadline

          sleep 0.1
        end
        Process.kill("INT", pid)
        _, status = Process.wait2(pid)

        assert_equal 130, status.exitstatus, "SIGINT should produce exit 130"
        report = JSON.parse(File.read(File.join(run_dir, "report.json")))
        assert_equal "crashed", report["status"]
      end
    end
  end

  def test_sample_project_mutation_marks_run_failed
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "mutation_guard", <<~YAML)
        name: mutation_guard
        steps:
          - kind: cli
            args: [version]
      YAML

      original = Hive::E2E::Sandbox.instance_method(:assert_sample_project_unmutated!)
      Hive::E2E::Sandbox.define_method(:assert_sample_project_unmutated!) do
        raise "sample project changed"
      end
      begin
        Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all
      ensure
        Hive::E2E::Sandbox.define_method(:assert_sample_project_unmutated!, original)
      end

      report = report_for(runs_dir)
      assert_equal 1, report["summary"]["failed"]
      assert_equal "failed", report["scenarios"].first["status"]
      assert_equal "sample_project_mutated", report["harness_errors"].first["kind"]
    end
  end

  def test_setup_failed_runs_use_failed_retention_window
    Dir.mktmpdir("runs") do |runs_dir|
      run_dir = File.join(runs_dir, "setup-failed")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "report.json"), JSON.pretty_generate(
        "status" => "complete",
        "summary" => { "failed" => 0, "setup_failed" => 1 }
      ))

      assert_equal 14, Hive::E2E::Sandbox.retention_days_for(run_dir, retain_days: 7, retain_failed_days: 14)
    end
  end

  def test_pending_incident_is_reported_without_executing_steps_or_counting_as_passed
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "pending_incident", <<~YAML)
        name: pending_incident
        description: Reproduces a synthetic pending incident.
        tags: [incident-regression]
        incident_id: pending-fixture
        sibling_task_id: "#9767"
        pending: true
        steps:
          - kind: ruby_block
            block: "raise 'pending steps must not execute'"
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all
      report = report_for(runs_dir)

      assert_equal "complete", report["status"]
      assert_equal({ "total" => 0, "passed" => 0, "failed" => 0, "setup_failed" => 0 }, report["summary"])
      assert_empty report["scenarios"]
      assert_equal [ {
        "name" => "pending_incident",
        "description" => "Reproduces a synthetic pending incident.",
        "tags" => [ "incident-regression" ],
        "incident_id" => "pending-fixture",
        "sibling_task_id" => "#9767",
        "pending" => true
      } ], report["scenario_metadata"]

      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::E2E::Schemas.schema_path("hive-e2e-report"))))
      assert_empty schema.validate(report).to_a

      legacy_report = report.reject { |key, _| key == "scenario_metadata" }
      assert_empty schema.validate(legacy_report).to_a,
                   "v1 reports produced before scenario_metadata was added must remain valid"
    end
  end

  def test_enabled_incident_metadata_is_additive_to_unchanged_result_shape
    with_isolated_dirs do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "enabled_incident", <<~YAML)
        name: enabled_incident
        description: Exercises an enabled synthetic incident.
        tags: [incident-regression]
        incident_id: enabled-fixture
        sibling_task_id: "#9767"
        pending: false
        steps:
          - kind: cli
            args: [version]
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all
      report = report_for(runs_dir)

      assert_equal 1, report["summary"]["total"]
      assert_equal "passed", report["scenarios"].first["status"]
      assert_equal %w[
        artifacts_dir duration_seconds error_summary failed_step_index failed_step_kind name repro status
      ], report["scenarios"].first.keys.map(&:to_s).sort
      assert_equal false, report["scenario_metadata"].first["pending"]
      assert_equal "enabled-fixture", report["scenario_metadata"].first["incident_id"]
    end
  end
end
