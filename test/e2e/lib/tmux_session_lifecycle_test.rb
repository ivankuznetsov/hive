require_relative "../../test_helper"
require "json"
require "rbconfig"
require "tmpdir"
require_relative "scenario"
require_relative "scenario_context"
require_relative "tmux_session_lifecycle"

class E2ETmuxSessionLifecycleTest < Minitest::Test
  SandboxDouble = Data.define(:sandbox_dir)

  def test_cleanup_terminates_unfinished_detached_tui_process_groups
    Dir.mktmpdir("sandbox") do |sandbox_dir|
      Dir.mktmpdir("home") do |run_home|
        Dir.mktmpdir("scenario") do |scenario_dir|
          context = Hive::E2E::ScenarioContext.new(
            sandbox: SandboxDouble.new(sandbox_dir: sandbox_dir), run_home: run_home, run_id: "run-123"
          )
          scenario = Hive::E2E::Scenario.new(
            name: "detached_child", description: "", tags: [], setup: {}, steps: [], path: "inline"
          )
          lifecycle = Hive::E2E::TmuxSessionLifecycle.new(
            scenario: scenario, sandbox_dir: sandbox_dir, run_home: run_home,
            run_id: "run-123", scenario_dir: scenario_dir, context: context
          )
          FileUtils.mkdir_p(lifecycle.tui_log_dir)
          pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
          waiter = Thread.new { Process.wait(pid) }
          registry = File.join(
            lifecycle.tui_log_dir, Hive::E2E::TmuxSessionLifecycle::MANAGED_SUBPROCESS_LOG_NAME
          )
          File.write(registry, JSON.generate("event" => "start", "id" => "deadbeef", "pid" => pid) + "\n")

          lifecycle.cleanup

          waiter.join(2)
          refute waiter.alive?, "cleanup must terminate and reap the detached TUI workflow child"
          assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
        ensure
          Process.kill("KILL", -pid) if pid && waiter&.alive?
          waiter&.join(1)
        end
      end
    end
  end

  def test_managed_subprocess_reader_waits_for_atomic_writer_record
    Dir.mktmpdir("sandbox") do |sandbox_dir|
      Dir.mktmpdir("home") do |run_home|
        Dir.mktmpdir("scenario") do |scenario_dir|
          context = Hive::E2E::ScenarioContext.new(
            sandbox: SandboxDouble.new(sandbox_dir: sandbox_dir), run_home: run_home, run_id: "run-123"
          )
          scenario = Hive::E2E::Scenario.new(
            name: "locked_registry", description: "", tags: [], setup: {}, steps: [], path: "inline"
          )
          lifecycle = Hive::E2E::TmuxSessionLifecycle.new(
            scenario: scenario, sandbox_dir: sandbox_dir, run_home: run_home,
            run_id: "run-123", scenario_dir: scenario_dir, context: context
          )
          FileUtils.mkdir_p(lifecycle.tui_log_dir)
          registry = File.join(
            lifecycle.tui_log_dir, Hive::E2E::TmuxSessionLifecycle::MANAGED_SUBPROCESS_LOG_NAME
          )

          File.open(registry, File::WRONLY | File::CREAT, 0o600) do |writer|
            writer.flock(File::LOCK_EX)
            writer.write('{"event":"start",')
            writer.flush
            reader = Thread.new { lifecycle.send(:active_managed_process_groups) }

            refute reader.join(0.05), "reader must wait instead of parsing a partial JSONL record"
            writer.write('"id":"deadbeef","pid":12345}' + "\n")
            writer.flush
            writer.flock(File::LOCK_UN)

            assert reader.join(1), "reader should resume when the writer releases its lock"
            assert_equal [ 12_345 ], reader.value
          ensure
            writer.flock(File::LOCK_UN) rescue nil
          end
        end
      end
    end
  end

  def test_start_strips_parent_bundler_environment_before_tmux_server_inherits_it
    Dir.mktmpdir("sandbox") do |sandbox_dir|
      Dir.mktmpdir("home") do |run_home|
        Dir.mktmpdir("scenario") do |scenario_dir|
          context = Hive::E2E::ScenarioContext.new(
            sandbox: SandboxDouble.new(sandbox_dir: sandbox_dir),
            run_home: run_home,
            run_id: "run-123"
          )
          scenario = Hive::E2E::Scenario.new(
            name: "tui_env_test", description: "", tags: [], setup: {}, steps: [], path: "inline"
          )
          lifecycle = Hive::E2E::TmuxSessionLifecycle.new(
            scenario: scenario, sandbox_dir: sandbox_dir, run_home: run_home,
            run_id: "run-123", scenario_dir: scenario_dir, context: context
          )

          observed = {}
          fake_tmux = Object.new
          fake_tmux.define_singleton_method(:start) do
            observed["RUBYOPT"] = ENV["RUBYOPT"]
            observed["BUNDLE_PATH"] = ENV["BUNDLE_PATH"]
          end
          original_available = Hive::E2E::TmuxDriver.method(:available?)
          original_new = Hive::E2E::TmuxDriver.method(:new)
          Hive::E2E::TmuxDriver.singleton_class.define_method(:available?) { true }
          Hive::E2E::TmuxDriver.singleton_class.define_method(:new) { |**_args| fake_tmux }
          lifecycle.define_singleton_method(:start_asciinema_if_available) { }
          previous_rubyopt = ENV["RUBYOPT"]
          previous_bundle_path = ENV["BUNDLE_PATH"]
          ENV["RUBYOPT"] = "-rbundler/setup"
          ENV["BUNDLE_PATH"] = "/outer/bundle"

          lifecycle.start_session

          assert_nil observed["RUBYOPT"]
          assert_nil observed["BUNDLE_PATH"]
        ensure
          ENV["RUBYOPT"] = previous_rubyopt
          ENV["BUNDLE_PATH"] = previous_bundle_path
          Hive::E2E::TmuxDriver.singleton_class.define_method(:available?, original_available)
          Hive::E2E::TmuxDriver.singleton_class.define_method(:new, original_new)
        end
      end
    end
  end

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
