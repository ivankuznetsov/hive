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
    skip "tmux is not installed" unless tmux_available?

    with_tmp_dir do |dir|
      runner = runner(name: unique_name("start"), cwd: dir)
      runner.start_detached(command: [ "sleep", "10" ])

      assert runner.session_exists?
    ensure
      runner&.kill_session
    end
  end

  def test_start_detached_applies_environment
    skip "tmux is not installed" unless tmux_available?

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
    skip "tmux is not installed" unless tmux_available?

    with_tmp_dir do |dir|
      out_path = File.join(dir, "prompt.bin")
      payload = "line one\n`rm -rf nope`\n'single quotes'\n</user_supplied_deadbeef>\n"
      reader = <<~RUBY
        system("stty raw -echo")
        bytes = Integer(ARGV[1])
        data = STDIN.read(bytes)
        File.binwrite(ARGV[0], data)
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

  def test_capture_pane_tail_returns_bounded_output
    skip "tmux is not installed" unless tmux_available?

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

  def test_kill_session_is_idempotent
    skip "tmux is not installed" unless tmux_available?

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
