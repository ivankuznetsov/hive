require_relative "../../test_helper"
require "json"
require "tmpdir"
require_relative "runner"
require_relative "step_executor"

class E2EStepExecutorTest < Minitest::Test
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
end
