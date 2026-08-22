require "test_helper"
require "rbconfig"
require "hive/invocation_process_custody"

class InvocationProcessCustodyTest < Minitest::Test
  include HiveTestHelper

  def test_cleanup_terminates_a_reparented_setsid_process_and_spares_another_run
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    first = Hive::InvocationProcessCustody.new
    second = Hive::InvocationProcessCustody.new
    owned = spawn_detached(first.environment)
    unrelated = spawn_detached(second.environment)

    first.cleanup!

    refute process_alive_with_start?(owned)
    assert process_alive_with_start?(unrelated)
  ensure
    terminate_exact(unrelated) if unrelated
    terminate_exact(owned) if owned
  end

  def test_environment_contains_only_one_opaque_custody_value
    custody = Hive::InvocationProcessCustody.new(token: "a" * 64)

    assert_equal(
      { Hive::InvocationProcessCustody::ENVIRONMENT_KEY => "a" * 64 },
      custody.environment
    )
  end

  def test_invalid_token_is_rejected
    assert_raises(ArgumentError) do
      Hive::InvocationProcessCustody.new(token: "predictable")
    end
  end

  private

  def spawn_detached(environment)
    reader, writer = IO.pipe
    writer.close_on_exec = false
    wrapper = Process.spawn(
      environment,
      RbConfig.ruby, "-e", <<~'RUBY', writer.fileno.to_s,
        writer = IO.for_fd(Integer(ARGV.fetch(0)))
        child = fork do
          Process.setsid
          writer.puts(Process.pid)
          writer.close
          trap("TERM") { exit! 0 }
          sleep
        end
        writer.close
        exit! 0
      RUBY
      out: File::NULL, err: File::NULL, close_others: false
    )
    writer.close
    Process.wait(wrapper)
    pid_text = reader.gets.to_s.strip
    reader.close
    pid = Integer(pid_text, 10)
    { pid: pid, start_time: Hive::ProcessKill.process_start_time(pid) }
  end

  def process_alive_with_start?(target)
    Hive::ProcessKill.captured_process_current?(target, require_identity: true)
  end

  def terminate_exact(target)
    return unless process_alive_with_start?(target)

    Process.kill("KILL", target.fetch(:pid))
  rescue Errno::ESRCH
    nil
  end
end
