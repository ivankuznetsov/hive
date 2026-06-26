require_relative "../../test_helper"
require_relative "background_process"
require "tmpdir"

class E2EBackgroundProcessTest < Minitest::Test
  include HiveTestHelper

  # Use a trivial long-lived hive invocation: `hive daemon start` in an empty
  # sandbox runs attached and ticks. We assert lifecycle (start → alive → stop),
  # not daemon behavior.
  def with_sandbox
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        yield sandbox, home
      end
    end
  end

  def test_starts_attached_and_stops
    with_sandbox do |sandbox, home|
      log = File.join(home, "bg.log")
      proc = Hive::E2E::BackgroundProcess.new(
        args: %w[daemon start],
        sandbox_dir: sandbox, run_home: home,
        env: { "HIVE_DAEMON_NO_AUTO_REEXEC" => "1" }, log_path: log
      ).start

      # Wait for liveness by polling, not a fixed sleep.
      deadline = Time.now + 10
      sleep 0.05 until proc.alive? || Time.now > deadline
      assert proc.alive?, "background daemon should be running"
      pgid = Process.getpgid(proc.pid)

      proc.stop
      sleep 0.05 while process_group_alive?(pgid) && Time.now < deadline
      refute process_group_alive?(pgid), "stop must terminate the process group"
    ensure
      proc&.stop # never leak the daemon if an assertion above fails
    end
  end

  def test_stop_skips_signals_after_child_was_reaped
    proc = Hive::E2E::BackgroundProcess.new(args: [], sandbox_dir: Dir.tmpdir, run_home: Dir.tmpdir)
    proc.instance_variable_set(:@pid, 12_345)
    proc.instance_variable_set(:@pgid, 12_345)

    kills = []
    with_replaced_singleton_method(Process, :waitpid, lambda { |pid, _flags| pid }) do
      with_replaced_singleton_method(Process, :kill, lambda { |signal, target| kills << [ signal, target ]; 1 }) do
        proc.stop
      end
    end

    assert_empty kills
    assert_nil proc.pid
  end

  def test_child_inherits_sandbox_home
    with_sandbox do |sandbox, home|
      log = File.join(home, "bg.log")
      proc = Hive::E2E::BackgroundProcess.new(
        args: %w[daemon start],
        sandbox_dir: sandbox, run_home: home,
        env: { "HIVE_DAEMON_NO_AUTO_REEXEC" => "1" }, log_path: log
      ).start
      deadline = Time.now + 10
      # The daemon writes its pid file under the sandbox HIVE_HOME, proving the
      # child inherited the injected env rather than the real home.
      sleep 0.05 until File.exist?(File.join(home, ".daemon.pid")) || Time.now > deadline
      assert File.exist?(File.join(home, ".daemon.pid")), "daemon pid file should land under the sandbox home"
    ensure
      proc&.stop
    end
  end

  def process_group_alive?(pgid)
    Process.kill(0, -pgid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
