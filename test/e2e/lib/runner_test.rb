require_relative "../../test_helper"
require "json"
require "tmpdir"
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
end
