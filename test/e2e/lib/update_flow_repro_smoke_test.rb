require_relative "../../test_helper"
require "bundler"
require "json"
require_relative "paths"
require_relative "repro_script_writer"
require_relative "scenario_parser"

# Real-process smoke test for the repro.sh artifact the harness writes when a
# CLI/daemon scenario fails. The update-flow scenarios added in PR #225 use
# the new stateful step kinds (start_releases_stub, spawn_background,
# stop_process) AND write/assert under {run_home}. Before the writer learned
# how to replay these kinds, the generated repro aborted at "step 1 not
# replayable" — losing the harness's main debug affordance.
#
# This test EXECUTES the generated bash, not just static-analyses it: it
# stands up the releases stub in a child process, launches `hive daemon start`
# under setsid (matching BackgroundProcess pgroup semantics), reads the
# resulting update_check.json, and confirms the daemon was reaped on EXIT.
#
# Marked as a smoke test because it really does fork ruby + hive children.
class E2EUpdateFlowReproSmokeTest < Minitest::Test
  def setup
    @scenarios_dir = Hive::E2E::Paths.scenarios_dir
  end

  def test_update_flow_pipeline_repro_runs_end_to_end
    scenario = Hive::E2E::ScenarioParser.parse(File.join(@scenarios_dir, "update_flow_pipeline.yml"))
    with_repro(scenario) do |script, sandbox, run_home|
      log = "#{script}.log"
      ok = run_repro_clean(script, log)
      assert ok, "generated repro.sh must exit 0 for update_flow_pipeline.yml — log:\n#{File.read(log)}"

      # The daemon's update_check.json proves the stub-driven probe ran: the
      # daemon wrote the canonical "behind" payload with the brew nudge.
      json_path = File.join(run_home, "update_check.json")
      assert File.exist?(json_path), "repro should have produced #{json_path}"
      json = File.read(json_path)
      assert_match(/"latest":\s*"999\.0\.0"/, json, "stub-driven probe must record the served tag")
      assert_match(/"channel":\s*"brew"/, json, "install-channel marker must select the brew nudge")

      # Background log is captured under run_home/background per the executor.
      assert File.exist?(File.join(run_home, "background", "daemon.log")),
             "spawn_background should write the daemon's stdout/stderr under run_home/background"

      # Sandbox isn't touched by the update flow but the repro still created it.
      assert File.directory?(sandbox), "sandbox dir must still exist after the repro completes"
    end
  end

  def test_update_flow_up_to_date_repro_runs_end_to_end
    scenario = Hive::E2E::ScenarioParser.parse(File.join(@scenarios_dir, "update_flow_up_to_date.yml"))
    with_repro(scenario) do |script, _sandbox, run_home|
      log = "#{script}.log"
      ok = run_repro_clean(script, log)
      assert ok, "generated repro.sh must exit 0 for update_flow_up_to_date.yml — log:\n#{File.read(log)}"

      json_path = File.join(run_home, "update_check.json")
      assert File.exist?(json_path), "up-to-date probe should still write update_check.json"
      json = JSON.parse(File.read(json_path))
      # "up-to-date" = served tag is below the running version, so no nudge
      # is persisted (UpdateCheck::State writes a null/absent nudge).
      refute json["nudge"], "up-to-date probe must not surface a nudge, got: #{json.inspect}"
    end
  end

  private

  # Run the generated repro.sh under a clean (unbundled) env so the daemon
  # child sees system gems instead of inheriting the test process's
  # BUNDLE_GEMFILE / RUBYOPT. The live harness uses the same pattern via
  # SandboxEnv.with → Bundler.with_unbundled_env; a real developer running
  # repro.sh from a normal shell is also outside `bundle exec`, so this
  # matches the intended invocation environment.
  def run_repro_clean(script, log)
    Bundler.with_unbundled_env do
      system("bash #{Shellwords.escape(script)} > #{Shellwords.escape(log)} 2>&1")
    end
  end

  # Build the full repro.sh for a scenario in a hermetic tmp tree (sandbox +
  # run_home as siblings, plus a synthetic Gemfile so SandboxEnv.repro_env's
  # BUNDLE_GEMFILE assignment doesn't break bundler when the repro shells out).
  def with_repro(scenario)
    Dir.mktmpdir("repro_smoke") do |root|
      scenario_dir = File.join(root, "scenarios", scenario.name)
      sandbox = File.join(root, "sandbox")
      run_home = File.join(root, "home")
      FileUtils.mkdir_p([ scenario_dir, sandbox, run_home ])
      File.write(File.join(sandbox, "Gemfile"), "source 'https://rubygems.org'\n")

      path = Hive::E2E::ReproScriptWriter.new(
        scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
        steps: scenario.steps, failed_index: scenario.steps.size,
        scenario_name: scenario.name
      ).write

      yield(path, sandbox, run_home)
    end
  end
end
