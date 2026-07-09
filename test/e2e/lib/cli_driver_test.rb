require_relative "../../test_helper"
require_relative "cli_driver"

class E2ECliDriverTest < Minitest::Test
  def test_calls_real_bin_hive_and_captures_output
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        driver = Hive::E2E::CliDriver.new(sandbox, home)

        result = driver.call([ "version" ], cwd: sandbox)

        assert_equal 0, result.exit_code
        assert_equal "#{Hive::VERSION}\n", result.stdout
      end
    end
  end

  def test_exit_mismatch_carries_stdout_and_stderr
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        driver = Hive::E2E::CliDriver.new(sandbox, home)

        error = assert_raises(Hive::E2E::CliDriver::ExitMismatchError) do
          driver.call([ "help" ], expect_exit: 7, cwd: sandbox)
        end
        assert_equal 7, error.expected
        assert_equal 0, error.actual
        assert_includes error.stdout, "Commands:"
      end
    end
  end

  def test_timeout_marks_result_and_kills_process_group
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        marker = File.join(sandbox, "timeout-fixture")
        command = write_timeout_fixture(sandbox)
        driver = Hive::E2E::CliDriver.new(sandbox, home)
        driver.define_singleton_method(:command) { |_args| [ command, marker ] }

        # Keep the timeout well under the fixture's 30s child sleep, but generous
        # enough that a slow/loaded CI worker reliably forks the shell and writes
        # "#{marker}.pgid" before the timeout kills it. A sub-second timeout races
        # fixture startup and makes the later File.read of the marker raise ENOENT.
        result = driver.call([ "ignored" ], expect_exit: nil, cwd: sandbox, timeout: 5.0)

        assert result.timed_out
        pgid = Integer(File.read("#{marker}.pgid").strip)
        refute_process_group_alive pgid
      ensure
        kill_process_group(marker)
      end
    end
  end

  def write_timeout_fixture(dir)
    command = File.join(dir, "timeout-fixture-command")
    File.write(command, <<~SH)
      #!/bin/sh
      marker="$1"
      (
        trap '' TERM
        sleep 30
      ) >/dev/null 2>&1 &
      child="$!"
      printf '%s\\n' "$child" > "$marker.pid"
      printf '%s\\n' "$$" > "$marker.pgid"
      wait "$child"
    SH
    File.chmod(0o755, command)
    command
  end

  def refute_process_group_alive(pgid)
    deadline = Time.now + 2
    sleep 0.05 while process_group_alive?(pgid) && Time.now < deadline
    refute process_group_alive?(pgid), "timeout must terminate the spawned process group"
  end

  def process_group_alive?(pgid)
    Process.kill(0, -pgid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def kill_process_group(marker)
    return unless marker && File.exist?("#{marker}.pgid")

    pgid = Integer(File.read("#{marker}.pgid").strip)
    Process.kill("KILL", -pgid) if process_group_alive?(pgid)
  rescue StandardError
    nil
  end
end
