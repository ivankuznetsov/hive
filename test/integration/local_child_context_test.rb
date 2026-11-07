# frozen_string_literal: true

require "test_helper"
require "timeout"
require "shellwords"
require "hive/connection_contexts"
require "hive/daemon/child_supervisor"
require "hive/bot/child_supervisor"
require "hive/one_shot/process_executor"
require "hive/tui/subprocess"

class LocalChildContextTest < Minitest::Test
  include HiveTestHelper

  HIVE = File.expand_path("../../bin/hive", __dir__)
  LOGICAL = [ HIVE, "runtime", "status", "--json" ].freeze

  def test_daemon_child_keeps_local_authority_and_its_logical_command
    with_remote_selected do |home, contexts|
      supervisor = Hive::Daemon::ChildSupervisor.new(hive_bin: HIVE,
        log_dir_for_task: ->(*) { File.join(home, "daemon-child.log") })
      command = "hive runtime status --json"
      supervisor.spawn(command_string: command, project: "demo", slug: "task", stage: "1-inbox")
      result = wait_for_exit(supervisor)
      assert_equal 0, result.exit_code, File.read(File.join(home, "daemon-child.log"))
      assert_equal "hive-runtime-maintenance", result.json_envelope.fetch("schema")
      assert_equal command, result.command
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  def test_bot_child_keeps_local_authority_and_its_logical_argv
    with_remote_selected do |home, contexts|
      logger = Object.new
      logger.define_singleton_method(:event) { |*_, **_| }
      supervisor = Hive::Bot::ChildSupervisor.new(logger: logger, hive_bin: HIVE,
        log_dir_for_task: ->(*) { File.join(home, "bot-child.log") })
      supervisor.dispatch(command_argv: LOGICAL, cwd: home, project: "demo", slug: "task", chat_id: 1, update_id: 2)
      result = wait_for_exit(supervisor)
      assert_equal 0, result.exit_code, File.read(File.join(home, "bot-child.log"))
      assert_equal LOGICAL, result.command_argv
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  def test_one_shot_native_child_keeps_local_authority
    with_remote_selected do |_home, contexts|
      execution = Hive::OneShot::ProcessExecutor.new.call(Shellwords.join(LOGICAL))
      assert_equal 0, execution.exit_code
      assert_equal "hive-runtime-maintenance", execution.envelope.fetch("schema")
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  def test_tui_quiet_and_takeover_native_children_keep_local_authority
    with_remote_selected do |home, contexts|
      with_env("HIVE_TUI_LOG_DIR" => File.join(home, "tui")) do
        exit_code, stdout, stderr = Hive::Tui::Subprocess.run_quiet!(LOGICAL)
        assert_equal 0, exit_code, stderr
        assert_equal "hive-runtime-maintenance", JSON.parse(stdout).fetch("schema")
        messages = []
        takeover = Hive::Tui::Subprocess.takeover_command(LOGICAL, dispatch: ->(message) { messages << message })
        _out, err = capture_subprocess_io do
          takeover.commands.find { |command| command.is_a?(Bubbletea::ExecCommand) }.callable.call
        end
        refute_includes err, "requires a local context"
        assert_equal [ 0 ], messages.map(&:exit_code)
        assert_equal [ "runtime" ], messages.map(&:verb)
      end
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  def test_tui_takeover_missing_native_binary_keeps_the_command_not_found_result
    with_remote_selected do |home, contexts|
      with_env("HIVE_TUI_LOG_DIR" => File.join(home, "tui")) do
        logical = [ File.join(home, "missing", "hive"), "runtime", "status", "--json" ]
        assert_equal 127, Hive::Tui::Subprocess.run_takeover_child_sync(logical)
        log = File.read(Hive::Tui::Subprocess.log_path)
        assert_includes log, Shellwords.join(logical)
        refute_includes log, "--context local"
      end
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  def test_tui_background_child_keeps_its_logical_verb_and_local_authority
    with_remote_selected do |home, contexts|
      with_env("HIVE_TUI_LOG_DIR" => File.join(home, "tui")) do
        messages = Queue.new
        assert_nil Hive::Tui::Subprocess.dispatch_background(LOGICAL, dispatch: ->(message) { messages << message })
        result = Timeout.timeout(15) { messages.pop }
        assert_equal 0, result.exit_code
        assert_equal "runtime", result.verb
        log = File.read(Hive::Tui::Subprocess.log_path)
        assert_includes log, Shellwords.join(LOGICAL)
        refute_includes log, "--context local"
      end
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  private

  def with_remote_selected
    with_tmp_global_config do |home|
      contexts = Hive::ConnectionContexts.new(verifier: ->(*) { { "instance_id" => "another-installation", "api_version" => "v1" } })
      contexts.add("elsewhere", url: "https://unreachable.invalid", token: "unused-fixture-bearer")
      contexts.use("elsewhere")
      yield home, contexts
    end
  end

  def wait_for_exit(supervisor)
    Timeout.timeout(15) do
      loop do
        result = supervisor.reap_all.first
        return result if result

        sleep 0.01
      end
    end
  end
end
