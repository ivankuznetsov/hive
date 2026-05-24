require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"

class RunBrainstormTmuxTest < Minitest::Test
  include HiveTestHelper

  def setup
    @socket = "hive-brainstorm-test-#{Process.pid}-#{object_id}"
    @old_socket = ENV["HIVE_TMUX_SOCKET"]
    @old_bin = ENV["HIVE_CLAUDE_BIN"]
    @old_poll = ENV["HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC"]
    @old_sentinel = ENV["HIVE_BRAINSTORM_TMUX_SENTINEL_INTERVAL_SEC"]
    @old_tmux_bin = ENV["HIVE_TMUX_BIN"]
    ENV["HIVE_TMUX_SOCKET"] = @socket
    ENV["HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC"] = "0.1"
    ENV["HIVE_BRAINSTORM_TMUX_SENTINEL_INTERVAL_SEC"] = "0.1"
  end

  def teardown
    kill_test_sessions
    ENV["HIVE_TMUX_SOCKET"] = @old_socket
    ENV["HIVE_CLAUDE_BIN"] = @old_bin
    ENV["HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC"] = @old_poll
    ENV["HIVE_BRAINSTORM_TMUX_SENTINEL_INTERVAL_SEC"] = @old_sentinel
    ENV["HIVE_TMUX_BIN"] = @old_tmux_bin
    ENV.delete("HIVE_FAKE_INTERACTIVE_SCENARIO")
  end

  def test_waiting_marker_completes_and_tears_down_tmux
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "waiting"
        folder = make_task_at_brainstorm(dir, timeout: 3)

        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "brainstorm.md"))
        assert_equal :waiting, marker.name
        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{\Ahive: 2-brainstorm/.* round_waiting\z}, log)
        assert_empty tmux_sessions
        refute File.exist?(File.join(folder, ".claude", "settings.json"))
        refute File.exist?(File.join(folder, ".done"))
      end
    end
  end

  def test_complete_marker_returns_complete_commit_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "complete"
        folder = make_task_at_brainstorm(dir, timeout: 3)

        capture_io { Hive::Commands::Run.new(folder).call }

        assert_equal :complete, Hive::Markers.current(File.join(folder, "brainstorm.md")).name
        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{\Ahive: 2-brainstorm/.* complete\z}, log)
        assert_empty tmux_sessions
      end
    end
  end

  def test_non_terminal_done_is_rearmed_until_marker_is_terminal
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "manual_then_complete"
        folder = make_task_at_brainstorm(dir, timeout: 5)

        capture_io { Hive::Commands::Run.new(folder).call }

        assert_equal :complete, Hive::Markers.current(File.join(folder, "brainstorm.md")).name
        result = JSON.parse(File.read(File.join(folder, "result.json")))
        assert_equal "second", result.fetch("turn")
        assert_empty tmux_sessions
      end
    end
  end

  def test_timeout_writes_error_marker_and_kills_session
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "hang"
        folder = make_task_at_brainstorm(dir, timeout: 1)

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(File.join(folder, "brainstorm.md"))
        assert_equal :error, marker.name
        assert_equal "timeout", marker.attrs["reason"]
        assert_empty tmux_sessions
      end
    end
  end

  def test_sentinel_fallback_completes_when_done_hook_never_fires
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "sentinel_complete"
        folder = make_task_at_brainstorm(dir, timeout: 3)

        capture_io { Hive::Commands::Run.new(folder).call }

        assert_equal :complete, Hive::Markers.current(File.join(folder, "brainstorm.md")).name
        assert_empty tmux_sessions
      end
    end
  end

  def test_sentinel_fallback_does_not_trust_pane_without_file_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "sentinel_echo_only"
        folder = make_task_at_brainstorm(dir, timeout: 1)

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(File.join(folder, "brainstorm.md"))
        assert_equal :error, marker.name
        assert_equal "timeout", marker.attrs["reason"]
        assert_empty tmux_sessions
      end
    end
  end

  def test_preexisting_session_rejects_double_spawn
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "waiting"
        folder = make_task_at_brainstorm(dir, timeout: 3)
        task = Hive::Task.new(folder)
        name = Hive::Stages::BrainstormTmux.session_name_for(task)
        system("tmux", "-L", @socket, "new-session", "-d", "-s", name, "sleep 10")

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }

        assert_equal Hive::ExitCodes::SOFTWARE, status
        assert_match(/already exists/, err)
        assert_includes tmux_sessions, name
      end
    end
  end

  def test_pane_crash_times_out_and_tears_down
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "crash"
        folder = make_task_at_brainstorm(dir, timeout: 1)

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        assert_equal :error, Hive::Markers.current(File.join(folder, "brainstorm.md")).name
        assert_empty tmux_sessions
      end
    end
  end

  def test_midrun_exception_still_tears_down_session
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        fake = write_fake_interactive_claude(dir)
        ENV["HIVE_CLAUDE_BIN"] = fake
        ENV["HIVE_FAKE_INTERACTIVE_SCENARIO"] = "hang"
        folder = make_task_at_brainstorm(dir, timeout: 5)
        task = Hive::Task.new(folder)
        cfg = Hive::Config.load(dir)
        # Capture the original `module_function`-installed singleton
        # method as an `UnboundMethod` so we can rebind it verbatim in
        # `ensure`. Wrapping the original via `Method#call` in a new
        # `define_singleton_method` (the prior approach) would compound
        # wrappers across test runs and across any second monkey-patch
        # in the same process. Using `define_method` with the captured
        # `UnboundMethod` restores the module to its untouched state.
        original = Hive::Stages::BrainstormTmux.singleton_class.instance_method(:wait_for_terminal_marker)
        Hive::Stages::BrainstormTmux.define_singleton_method(:wait_for_terminal_marker) do |_task, _runner, _timeout|
          raise "forced midrun failure"
        end

        assert_raises(RuntimeError) { Hive::Stages::BrainstormTmux.run!(task, cfg) }
        assert_empty tmux_sessions
      ensure
        if original
          Hive::Stages::BrainstormTmux.singleton_class.send(:define_method, :wait_for_terminal_marker, original)
        end
      end
    end
  end

  private

  def make_task_at_brainstorm(dir, timeout:)
    project = File.basename(dir)
    capture_io do
      Hive::Commands::Init.new(dir).call
      Hive::Commands::New.new(project, "test brainstorm").call
    end
    config_path = File.join(dir, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(config_path))
    cfg["brainstorm"]["runtime"] = "tmux_interactive"
    cfg["timeout_sec"]["brainstorm"] = timeout
    File.write(config_path, cfg.to_yaml)

    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    target = File.join(dir, ".hive-state", "stages", "2-brainstorm", File.basename(inbox))
    FileUtils.mv(inbox, target)
    target
  end

  def write_fake_interactive_claude(dir)
    path = File.join(dir, "fake-interactive-claude")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      require "open3"

      if ARGV == ["--version"]
        puts "2.1.118 (Claude Code)"
        exit 0
      end

      puts "Claude Code v2.1.118"
      puts "❯"
      STDOUT.flush
      STDIN.gets
      stage_dir = ENV.fetch("HIVE_TASK_STAGE_DIR")
      state_file = File.join(stage_dir, "brainstorm.md")
      scenario = ENV.fetch("HIVE_FAKE_INTERACTIVE_SCENARIO")

      def fire_hook(turn)
        settings = JSON.parse(File.read(File.join(Dir.pwd, ".claude", "settings.json")))
        handler = settings.fetch("hooks").fetch("Stop").fetch(0).fetch("hooks").fetch(0)
        payload = JSON.generate("turn" => turn, "session_id" => "fake-session")
        # Claude Code invokes the hook command via a shell; mirror that so
        # the `HIVE_TASK_STAGE_DIR=…` prefix in the shell-string command is
        # interpreted as an environment assignment.
        _out, err, status = Open3.capture3("bash", "-c", handler.fetch("command"), stdin_data: payload)
        abort(err) unless status.success?
      end

      def wait_for_done_cleared
        done = File.join(ENV.fetch("HIVE_TASK_STAGE_DIR"), ".done")
        deadline = Time.now + 5
        while File.exist?(done)
          raise "orchestrator never cleared .done" if Time.now >= deadline
          sleep 0.05
        end
      end

      case scenario
      when "waiting"
        File.write(state_file, "## Round 1\\n### Q1. Scope?\\n### A1.\\n\\n<!-- WAITING -->\\n")
        puts "<!-- WAITING -->"
        fire_hook("waiting")
      when "complete"
        File.write(state_file, "## Requirements\\n- Done\\n<!-- COMPLETE -->\\n")
        puts "<!-- COMPLETE -->"
        fire_hook("complete")
      when "manual_then_complete"
        fire_hook("first")
        wait_for_done_cleared
        File.write(state_file, "## Requirements\\n- Done after manual turn\\n<!-- COMPLETE -->\\n")
        puts "<!-- COMPLETE -->"
        fire_hook("second")
      when "hang"
        sleep 10
      when "crash"
        exit 1
      when "sentinel_complete"
        File.write(state_file, "## Requirements\\n- Done via sentinel\\n<!-- COMPLETE -->\\n")
        puts "<!-- COMPLETE -->"
        sleep 10
      when "sentinel_echo_only"
        puts "<!-- COMPLETE -->"
        sleep 10
      else
        abort("unknown scenario: \#{scenario}")
      end
    RUBY
    File.chmod(0o755, path)
    path
  end

  def tmux_sessions
    out = `tmux -L #{@socket.shellescape} ls 2>/dev/null`
    return [] unless $CHILD_STATUS&.success?

    out.lines.map { |line| line.split(":", 2).first }
  end

  def kill_test_sessions
    tmux_sessions.each do |name|
      system("tmux", "-L", @socket, "kill-session", "-t", name, out: File::NULL, err: File::NULL)
    end
  end
end
