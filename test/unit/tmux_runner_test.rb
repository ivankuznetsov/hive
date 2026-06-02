require "test_helper"
require "hive/tmux_runner"

class TmuxRunnerTest < Minitest::Test
  include HiveTestHelper

  def setup
    @socket_name = "hive-test-#{Process.pid}-#{object_id}"
  end

  def teardown
    return unless tmux_available?

    out = `tmux -L #{@socket_name.shellescape} ls 2>/dev/null`
    out.each_line do |line|
      name = line.split(":", 2).first
      system("tmux", "-L", @socket_name, "kill-session", "-t", name) if name&.start_with?("hive-test-")
    end
  end

  def test_start_detached_creates_a_session
    with_tmp_dir do |dir|
      runner = runner(name: unique_name("start"), cwd: dir)
      runner.start_detached(command: [ "sleep", "10" ])

      assert runner.session_exists?
    ensure
      runner&.kill_session
    end
  end

  def test_start_detached_applies_environment
    with_tmp_dir do |dir|
      out_path = File.join(dir, "env.txt")
      runner = runner(name: unique_name("env"), cwd: dir, env: { "HIVE_TMUX_TEST_VALUE" => "ok" })
      runner.start_detached(command: [ "ruby", "-e", "File.write(ARGV[0], ENV.fetch('HIVE_TMUX_TEST_VALUE'))", out_path ])

      wait_for_file(out_path)

      assert_equal "ok", File.read(out_path)
    ensure
      runner&.kill_session
    end
  end

  def test_send_prompt_injects_payload_without_shell_corruption
    with_tmp_dir do |dir|
      out_path = File.join(dir, "prompt.bin")
      payload = "line one\n`rm -rf nope`\n'single quotes'\n</user_supplied_deadbeef>\n"
      reader = <<~RUBY
        system("stty raw -echo")
        bytes = Integer(ARGV[1])
        data = STDIN.read(bytes)
        File.binwrite(ARGV[0], data)
        sleep 1
      RUBY
      runner = runner(name: unique_name("prompt"), cwd: dir)
      runner.start_detached(command: [ "ruby", "-e", reader, out_path, payload.bytesize.to_s ])
      runner.send_prompt(payload)

      wait_for_file(out_path)

      assert_equal payload, File.binread(out_path)
    ensure
      runner&.kill_session
    end
  end

  def test_send_prompt_raises_when_server_disappears_before_enter_submit
    with_tmp_dir do |dir|
      log_path = File.join(dir, "tmux.log")
      fake = write_fake_tmux(dir, <<~RUBY)
        #!/usr/bin/env ruby
        args = ARGV.dup
        args.shift(2) if args.first == "-L"
        File.open(#{log_path.dump}, "a") { |log| log.puts(args.join(" ")) }
        case args.first
        when "load-buffer", "paste-buffer", "delete-buffer"
          exit 0
        when "send-keys"
          warn "no server running on /tmp/tmux-test"
          exit 1
        else
          exit 0
        end
      RUBY
      runner = Hive::TmuxRunner.new(
        name: unique_name("submit-lost"),
        cwd: dir,
        tmux_bin: fake,
        socket_name: @socket_name
      )

      error = assert_raises(Hive::TmuxRunner::NoServerRunning) do
        runner.send_prompt("hello")
      end

      assert_match(/send-keys/, error.message)
      assert_prompt_buffer_cleaned_up(log_path)
    end
  end

  def test_send_prompt_times_out_when_enter_submit_hangs
    with_tmp_dir do |dir|
      log_path = File.join(dir, "tmux.log")
      fake = write_fake_tmux(dir, <<~RUBY)
        #!/usr/bin/env ruby
        args = ARGV.dup
        args.shift(2) if args.first == "-L"
        File.open(#{log_path.dump}, "a") { |log| log.puts(args.join(" ")) }
        case args.first
        when "load-buffer", "paste-buffer", "delete-buffer"
          exit 0
        when "send-keys"
          sleep 5
          exit 0
        else
          exit 0
        end
      RUBY
      runner = Hive::TmuxRunner.new(
        name: unique_name("submit-hang"),
        cwd: dir,
        tmux_bin: fake,
        socket_name: @socket_name
      )

      # 1.0s, not 0.25s: each fake-tmux invocation is a fresh Ruby process
      # (~100-200ms startup, more under CI load), so the FIRST `load-buffer`
      # call can exceed a sub-second budget and trip the timeout on the wrong
      # command before `send-keys`'s 5s sleep is reached. Give Ruby startup
      # comfortable headroom; the timeout still fires at 1s on send-keys.
      error = with_env("HIVE_TMUX_COMMAND_TIMEOUT_SEC" => "1.0") do
        assert_raises(Hive::TmuxRunner::CommandTimedOut) do
          runner.send_prompt("hello")
        end
      end

      assert_match(/send-keys/, error.message)
      assert_match(/timed out after 1.0s/, error.message)
      assert_prompt_buffer_cleaned_up(log_path)
    end
  end

  def test_capture_pane_tail_returns_bounded_output
    with_tmp_dir do |dir|
      runner = runner(name: unique_name("tail"), cwd: dir)
      runner.start_detached(command: "bash -lc 'printf abcdefghijklmnopqrstuvwxyz; sleep 10'")
      tail = nil
      20.times do
        tail = runner.capture_pane_tail(bytes: 10)
        break if tail.include?("uvwxyz")

        sleep 0.1
      end

      assert_operator tail.bytesize, :<=, 10
      assert_includes tail, "uvwxyz"
    ensure
      runner&.kill_session
    end
  end

  def test_session_exists_returns_false_when_tmux_missing
    with_tmp_dir do |dir|
      runner = Hive::TmuxRunner.new(name: unique_name("missing-exists"), cwd: dir, tmux_bin: "missing-tmux-for-hive")

      refute runner.session_exists?
    end
  end

  def test_pane_pid_returns_nil_for_non_integer_output
    with_tmp_dir do |dir|
      fake = write_fake_tmux(dir, <<~SH)
        #!/bin/sh
        if [ "$1" = "display-message" ]; then
          echo not-a-pid
          exit 0
        fi
        exit 0
      SH
      runner = Hive::TmuxRunner.new(name: unique_name("pane-pid"), cwd: dir, tmux_bin: fake)

      assert_nil runner.pane_pid
    end
  end

  def test_capture_pane_tail_scrubs_invalid_utf8
    with_tmp_dir do |dir|
      fake = write_fake_tmux(dir, <<~SH)
        #!/usr/bin/env ruby
        if ARGV.first == "capture-pane"
          STDOUT.binmode
          STDOUT.write("ok\\xC3bad")
          exit 0
        end
        exit 0
      SH
      runner = Hive::TmuxRunner.new(name: unique_name("invalid"), cwd: dir, tmux_bin: fake)

      tail = runner.capture_pane_tail(bytes: 100)

      assert_predicate tail, :valid_encoding?
      assert_includes tail, "ok"
      assert_includes tail, "bad"
    end
  end

  def test_capture_pane_tail_scrubs_after_byte_slice
    with_tmp_dir do |dir|
      fake = write_fake_tmux(dir, <<~SH)
        #!/usr/bin/env ruby
        if ARGV.first == "capture-pane"
          print "abcé"
          exit 0
        end
        exit 0
      SH
      runner = Hive::TmuxRunner.new(name: unique_name("slice"), cwd: dir, tmux_bin: fake)

      tail = runner.capture_pane_tail(bytes: 1)

      assert_predicate tail, :valid_encoding?
    end
  end

  def test_kill_session_is_idempotent
    with_tmp_dir do |dir|
      runner = runner(name: unique_name("kill"), cwd: dir)
      runner.start_detached(command: [ "sleep", "10" ])

      assert runner.kill_session
      assert runner.kill_session
      refute runner.session_exists?
    end
  end

  def test_missing_tmux_raises_typed_error
    with_tmp_dir do |dir|
      runner = Hive::TmuxRunner.new(name: unique_name("missing"), cwd: dir, tmux_bin: "missing-tmux-for-hive")

      assert_raises(Hive::TmuxRunner::ExecutableMissing) { runner.start_detached(command: [ "sleep", "1" ]) }
    end
  end

  def test_tmux_server_unavailable_raises_typed_error
    with_tmp_dir do |dir|
      fake = write_fake_tmux(dir, <<~SH)
        #!/bin/sh
        echo "no server running on /tmp/tmux-test" >&2
        exit 1
      SH
      runner = Hive::TmuxRunner.new(name: unique_name("no-server"), cwd: dir, tmux_bin: fake)

      assert_raises(Hive::TmuxRunner::NoServerRunning) { runner.capture_pane_tail(bytes: 10) }
      assert runner.kill_session
    end
  end

  private

  def assert_prompt_buffer_cleaned_up(log_path)
    lines = File.read(log_path).lines.map(&:strip)
    load_index = command_index(lines, "load-buffer")
    paste_index = command_index(lines, "paste-buffer")
    send_index = command_index(lines, "send-keys")
    delete_index = command_index(lines, "delete-buffer")
    buffer_name = option_value(lines.fetch(load_index), "-b")

    assert_operator load_index, :<, paste_index
    assert_operator paste_index, :<, send_index
    assert_operator send_index, :<, delete_index
    assert_equal buffer_name, option_value(lines.fetch(paste_index), "-b")
    assert_equal buffer_name, option_value(lines.fetch(delete_index), "-b")
  end

  def command_index(lines, command)
    index = lines.index { |line| line.split.first == command }
    flunk "missing tmux #{command} call in #{lines.inspect}" unless index

    index
  end

  def option_value(line, option)
    parts = line.split
    option_index = parts.index(option)
    flunk "missing #{option} in #{line.inspect}" unless option_index

    parts.fetch(option_index + 1)
  end

  def runner(name:, cwd:, env: {})
    Hive::TmuxRunner.new(name: name, cwd: cwd, env: env, socket_name: @socket_name)
  end

  def unique_name(suffix)
    "hive-test-#{suffix}-#{Process.pid}-#{rand(10_000)}"
  end

  def tmux_available?
    system("tmux", "-V", out: File::NULL, err: File::NULL)
  end

  def wait_for_file(path)
    50.times do
      return if File.exist?(path)

      sleep 0.1
    end
    flunk "timed out waiting for #{path}"
  end

  def write_fake_tmux(dir, body)
    path = File.join(dir, "tmux")
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end
