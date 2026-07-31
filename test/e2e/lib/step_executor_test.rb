require_relative "../../test_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "runner"
require_relative "step_executor"

class E2EStepExecutorTest < Minitest::Test
  def test_patrol_evidence_is_confined_and_preserves_success_artifacts
    Dir.mktmpdir("e2e-patrol-evidence") do |root|
      sandbox_dir = File.join(root, "sandbox")
      run_home = File.join(root, "home")
      scenario_dir = File.join(root, "run", "scenarios", "patrol")
      FileUtils.mkdir_p([ sandbox_dir, run_home, scenario_dir ])
      sandbox = Struct.new(:sandbox_dir, :run_home).new(sandbox_dir, run_home)
      step = Hive::E2E::Step.new(
        kind: "patrol_evidence",
        args: {},
        description: "",
        position: 1
      )
      scenario = Hive::E2E::Scenario.new(
        name: "patrol", description: "", tags: [], setup: {},
        steps: [ step ], path: "inline"
      )
      calls = []
      qualification_run_id = "patrol-#{"1" * 64}"
      runner = Object.new
      runner.define_singleton_method(:call) do |project_root:, run_home:, artifacts_root:|
        artifacts_dir = File.join(
          artifacts_root, qualification_run_id
        )
        calls << {
          project_root: project_root, run_home: run_home,
          artifacts_root: artifacts_root
        }
        FileUtils.mkdir_p(artifacts_dir)
        File.write(
          File.join(artifacts_dir, "result.json"),
          JSON.generate("run_id" => qualification_run_id,
                        "status" => "deterministic_evidence_ready")
        )
        {
          "run_id" => qualification_run_id,
          "status" => "deterministic_evidence_ready",
          "artifacts_dir" => artifacts_dir
        }
      end
      executor = Hive::E2E::StepExecutor.new(
        scenario: scenario, sandbox: sandbox,
        scenario_dir: scenario_dir, run_id: "outer-run"
      )
      executor.instance_variable_set(:@patrol_evidence_runner, runner)

      result = executor.execute

      assert_equal "passed", result.status
      assert_equal 1, calls.size
      call = calls.first
      assert_equal File.expand_path(sandbox_dir),
                   File.expand_path(call.fetch(:project_root))
      assert_equal File.expand_path(run_home),
                   File.expand_path(call.fetch(:run_home))
      assert Hive::E2E::PathSafety.contained?(
        scenario_dir, call.fetch(:artifacts_root)
      )
      assert_equal(
        File.join(scenario_dir, "patrol-evidence"),
        call.fetch(:artifacts_root)
      )
      assert File.file?(
        File.join(
          call.fetch(:artifacts_root), qualification_run_id,
          "result.json"
        )
      )
    end
  end

  def test_patrol_evidence_rejects_non_proof_outcomes_and_keeps_failure_replay
    %w[pending skipped unsupported blocked failed evidence_required].each do |status|
      with_runner do |scenarios_dir, runs_dir|
        write_scenario(scenarios_dir, "patrol_#{status}", <<~YAML)
          name: patrol_#{status}
          steps:
            - kind: patrol_evidence
        YAML
        runner = Hive::E2E::Runner.new(
          scenarios_dir: scenarios_dir, runs_dir: runs_dir
        )
        executor_class = Hive::E2E::StepExecutor
        original_new = executor_class.method(:new)
        fake = Object.new
        qualification_run_id = "patrol-#{"2" * 64}"
        fake.define_singleton_method(:call) do |project_root:, run_home:, artifacts_root:|
          artifacts_dir = File.join(
            artifacts_root, qualification_run_id
          )
          FileUtils.mkdir_p(artifacts_dir)
          File.write(
            File.join(artifacts_dir, "result.json"),
            JSON.generate(
              "run_id" => qualification_run_id,
              "status" => status
            )
          )
          {
            "run_id" => qualification_run_id,
            "status" => status,
            "artifacts_dir" => artifacts_dir
          }
        end
        executor_class.define_singleton_method(:new) do |**kwargs|
          original_new.call(**kwargs).tap do |executor|
            executor.instance_variable_set(:@patrol_evidence_runner, fake)
          end
        end
        begin
          runner.run_all
        ensure
          executor_class.define_singleton_method(:new, original_new)
        end

        report = report_for(runs_dir)
        row = report.fetch("scenarios").first
        assert_equal "failed", row.fetch("status"), status
        assert_equal "patrol_evidence", row.fetch("failed_step_kind")
        assert_match(/not qualifying proof/, row.fetch("error_summary"))
        scenario_artifacts = File.join(
          Dir[File.join(runs_dir, "*")].first,
          row.fetch("artifacts_dir")
        )
        assert File.file?(
          File.join(
            scenario_artifacts, "patrol-evidence",
            qualification_run_id, "result.json"
          )
        )
        repro = File.read(File.join(scenario_artifacts, "repro.sh"))
        assert_includes repro, "patrol_qualification_runner"
        refute_includes repro, "skipped: kind=patrol_evidence"
      end
    end
  end

  def test_tmux_is_quiesced_before_final_github_verification
    Dir.mktmpdir("e2e-executor") do |root|
      sandbox_dir = File.join(root, "sandbox")
      run_home = File.join(root, "home")
      scenario_dir = File.join(root, "run", "scenarios", "quiescence")
      FileUtils.mkdir_p([ sandbox_dir, run_home, scenario_dir ])
      sandbox = Struct.new(:sandbox_dir, :run_home).new(sandbox_dir, run_home)
      scenario = Hive::E2E::Scenario.new(
        name: "quiescence", description: "", tags: [], setup: {}, steps: [], path: "inline"
      )
      events = []
      lifecycle = Object.new
      lifecycle.define_singleton_method(:failure_evidence) { events << :snapshot; {} }
      lifecycle.define_singleton_method(:stop_asciinema) { |delete:| events << [ :stop_asciinema, delete ] }
      lifecycle.define_singleton_method(:cleanup) { events << :tmux_cleanup }
      lifecycle.define_singleton_method(:discard_preserved_cast) { events << :discard_cast }
      lifecycle.define_singleton_method(:tui_log_dir) { nil }
      gh_stub = Object.new
      gh_stub.define_singleton_method(:verify!) { events << :gh_verify }
      executor = Hive::E2E::StepExecutor.new(
        scenario: scenario, sandbox: sandbox, scenario_dir: scenario_dir, run_id: "quiescence"
      )
      executor.instance_variable_set(:@tmux_lifecycle, lifecycle)
      executor.instance_variable_set(:@gh_stub, gh_stub)

      result = executor.execute

      assert_equal "passed", result.status
      assert_operator events.index(:snapshot), :<, events.index(:tmux_cleanup)
      assert_operator events.index(:tmux_cleanup), :<, events.index(:gh_verify)
    end
  end

  def test_quiescence_attempts_registered_background_cleanup_when_tmux_cleanup_fails
    events = []
    lifecycle = Object.new
    lifecycle.define_singleton_method(:stop_asciinema) { |delete:| events << [ :asciinema, delete ] }
    lifecycle.define_singleton_method(:cleanup) { raise "tmux cleanup failed" }
    background = Object.new
    background.define_singleton_method(:stop) { events << :background_stop }
    context = Struct.new(:harness_state).new({ background: { "worker" => background } })
    executor = Hive::E2E::StepExecutor.allocate
    executor.instance_variable_set(:@tmux_lifecycle, lifecycle)
    executor.instance_variable_set(:@ctx, context)

    error = assert_raises(RuntimeError) do
      executor.send(:quiesce_harness, preserve_cast: false)
    end

    assert_equal "tmux cleanup failed", error.message
    assert_includes events, :background_stop
  end

  def with_runner
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

  def test_cli_step_happy_path
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "cli_ok", <<~YAML)
        name: cli_ok
        steps:
          - kind: cli
            args: [version]
            expect_exit: 0
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      assert_equal 1, report_for(runs_dir)["summary"]["passed"]
    end
  end

  def test_cli_step_expect_exit_mismatch_fails
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "cli_mismatch", <<~YAML)
        name: cli_mismatch
        steps:
          - kind: cli
            args: [version]
            expect_exit: 99
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      report = report_for(runs_dir)
      assert_equal 1, report["summary"]["failed"], "exit-code mismatch should mark scenario failed"
      assert_equal "failed", report["scenarios"].first["status"]
    end
  end

  def test_state_assert_present_and_absent
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "state_present", <<~YAML)
        name: state_present
        steps:
          - kind: write_file
            path: "{sandbox}/marker.txt"
            content: "yes"
          - kind: state_assert
            path: "{sandbox}/marker.txt"
            contains: "yes"
          - kind: state_assert
            path: "{sandbox}/never-there.txt"
            absent: true
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      assert_equal 1, report_for(runs_dir)["summary"]["passed"]
    end
  end

  def test_state_assert_supports_glob_paths
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "state_glob", <<~YAML)
        name: state_glob
        steps:
          - kind: write_file
            path: "{sandbox}/nested/generated/idea.md"
            content: "# generated title\\n"
          - kind: state_assert
            path: "{sandbox}/nested/*/idea.md"
            glob: true
            contains: "# generated title"
          - kind: state_assert
            path: "{sandbox}/nested/nope/*.md"
            glob: true
            absent: true
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      assert_equal 1, report_for(runs_dir)["summary"]["passed"]
    end
  end

  def test_path_only_state_assert_requires_file_to_exist
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "missing_path_assert", <<~YAML)
        name: missing_path_assert
        steps:
          - kind: state_assert
            path: "{sandbox}/missing.txt"
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      report = report_for(runs_dir)
      assert_equal 1, report["summary"]["failed"]
      assert_match(/expected .*missing\.txt to exist/, report["scenarios"].first["error_summary"])
    end
  end

  def test_write_file_rejects_paths_outside_sandbox
    Dir.mktmpdir("outside") do |outside|
      target = File.join(outside, "escaped.txt")
      with_runner do |scenarios_dir, runs_dir|
        write_scenario(scenarios_dir, "escape_write", <<~YAML)
          name: escape_write
          steps:
            - kind: write_file
              path: #{target.inspect}
              content: "bad"
        YAML

        Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

        report = report_for(runs_dir)
        assert_equal 1, report["summary"]["failed"]
        refute File.exist?(target), "write_file must not create files outside the sandbox"
      end
    end
  end

  def test_state_assert_marker_semantics
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "state_marker", <<~YAML)
        name: state_marker
        steps:
          - kind: seed_state
            stage: 2-brainstorm
            slug: marker-task
            state_file: brainstorm.md
            content: "# task\\n\\n<!-- COMPLETE -->\\n"
          - kind: state_assert
            path: "{task_dir:2-brainstorm}/brainstorm.md"
            marker: { current: COMPLETE }
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      assert_equal 1, report_for(runs_dir)["summary"]["passed"]
    end
  end

  def test_json_assert_ok_path
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "json_ok", <<~YAML)
        name: json_ok
        steps:
          - kind: json_assert
            args: [status, --json]
            schema: hive-status
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      assert_equal 1, report_for(runs_dir)["summary"]["passed"]
    end
  end

  def test_json_assert_invalid_path
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "json_invalid", <<~YAML)
        name: json_invalid
        steps:
          - kind: cli
            args: [version]
          - kind: json_assert
            args: [version]
            schema: hive-status
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      report = report_for(runs_dir)
      assert_equal 1, report["summary"]["failed"], "json_assert against non-JSON output should fail"
    end
  end

  def test_seed_state_plants_markers
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "seed_test", <<~YAML)
        name: seed_test
        steps:
          - kind: seed_state
            stage: 2-brainstorm
            slug: seeded-slug
            state_file: brainstorm.md
            content: "# seeded\\n\\n<!-- COMPLETE -->\\n"
            files:
              - path: extra.md
                content: "extra body"
          - kind: state_assert
            path: "{task_dir:2-brainstorm}/brainstorm.md"
            contains: "seeded"
          - kind: state_assert
            path: "{task_dir:2-brainstorm}/extra.md"
            contains: "extra body"
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      assert_equal 1, report_for(runs_dir)["summary"]["passed"]
    end
  end

  def test_scripted_gh_is_inherited_by_blocking_and_background_hive_processes
    with_runner do |scenarios_dir, runs_dir|
      write_scenario(scenarios_dir, "gh_inheritance", <<~YAML)
        name: gh_inheritance
        steps:
          - kind: script_gh
            interactions:
              - args: [auth, status]
              - args: [auth, status]
          - kind: cli
            args: [setup, --no-bootstrap, --no-init, --json]
            expect_exit:
          - kind: spawn_background
            id: setup
            args: [setup, --no-bootstrap, --no-init, --json]
          - kind: state_assert
            path: "{run_home}/gh-stub/state.json"
            contains: '"next_index":2'
            timeout: 10
          - kind: stop_process
            id: setup
      YAML

      Hive::E2E::Runner.new(scenarios_dir: scenarios_dir, runs_dir: runs_dir).run_all

      report = report_for(runs_dir)
      assert_equal 1, report["summary"]["passed"], report["scenarios"].inspect
    end
  end
end
