require_relative "../../test_helper"
require_relative "background_process"
require "tmpdir"

class E2EBackgroundProcessTest < Minitest::Test
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

      proc.stop
      sleep 0.05 while proc.alive? && Time.now < deadline
      refute proc.alive?, "stop must terminate the process group"
    end
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
end
