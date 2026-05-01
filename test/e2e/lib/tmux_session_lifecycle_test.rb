require_relative "../../test_helper"
require "tmpdir"
require_relative "scenario"
require_relative "scenario_context"
require_relative "tmux_session_lifecycle"

class E2ETmuxSessionLifecycleTest < Minitest::Test
  SandboxDouble = Data.define(:sandbox_dir)

  def test_session_env_expands_tui_setup_placeholders_and_scopes_logs
    Dir.mktmpdir("sandbox") do |sandbox_dir|
      Dir.mktmpdir("home") do |run_home|
        Dir.mktmpdir("scenario") do |scenario_dir|
          context = Hive::E2E::ScenarioContext.new(
            sandbox: SandboxDouble.new(sandbox_dir: sandbox_dir),
            run_home: run_home,
            run_id: "run-123"
          )
          context.slug_default!("ready-task")
          scenario = Hive::E2E::Scenario.new(
            name: "tui_env_test",
            description: "",
            tags: [],
            setup: {
              "tui_env" => {
                "HIVE_FAKE_CLAUDE_WRITE_FILE" => "{task_dir:3-plan}/plan.md",
                "HIVE_FAKE_CLAUDE_WRITE_CONTENT" => "{slug}"
              }
            },
            steps: [],
            path: "inline"
          )
          lifecycle = Hive::E2E::TmuxSessionLifecycle.new(
            scenario: scenario,
            sandbox_dir: sandbox_dir,
            run_home: run_home,
            run_id: "run-123",
            scenario_dir: scenario_dir,
            context: context
          )

          env = lifecycle.send(:session_env)

          assert_equal File.join(sandbox_dir, ".hive-state", "stages", "3-plan", "ready-task", "plan.md"),
                       env["HIVE_FAKE_CLAUDE_WRITE_FILE"]
          assert_equal "ready-task", env["HIVE_FAKE_CLAUDE_WRITE_CONTENT"]
          assert_equal File.join(scenario_dir, "tui-subprocess-live"), env["HIVE_TUI_LOG_DIR"]
        end
      end
    end
  end

  def test_session_env_rejects_reserved_tui_log_dir_override
    Dir.mktmpdir("sandbox") do |sandbox_dir|
      Dir.mktmpdir("home") do |run_home|
        Dir.mktmpdir("scenario") do |scenario_dir|
          context = Hive::E2E::ScenarioContext.new(
            sandbox: SandboxDouble.new(sandbox_dir: sandbox_dir),
            run_home: run_home,
            run_id: "run-123"
          )
          scenario = Hive::E2E::Scenario.new(
            name: "tui_env_test",
            description: "",
            tags: [],
            setup: { "tui_env" => { "HIVE_TUI_LOG_DIR" => "/tmp/other" } },
            steps: [],
            path: "inline"
          )
          lifecycle = Hive::E2E::TmuxSessionLifecycle.new(
            scenario: scenario,
            sandbox_dir: sandbox_dir,
            run_home: run_home,
            run_id: "run-123",
            scenario_dir: scenario_dir,
            context: context
          )

          error = assert_raises(ArgumentError) { lifecycle.send(:session_env) }
          assert_includes error.message, "HIVE_TUI_LOG_DIR"
        end
      end
    end
  end
end
