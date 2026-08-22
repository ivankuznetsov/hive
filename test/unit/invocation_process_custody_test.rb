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

  def test_a_process_that_outlives_term_and_kill_fails_the_cleanup
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      # A signalled child stays in procfs as an unreaped zombie, so the
      # inventory keeps matching it after both signals have been spent.
      lingering = Process.spawn(
        RbConfig.ruby, "-e", "trap('TERM') { exit! 0 }; sleep",
        out: File::NULL, err: File::NULL
      )
      write_proc_entry(dir, lingering, environ: custody_environ(TOKEN))
      custody = build_custody(dir)

      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        custody.cleanup!
      end

      assert_match(/1 process\(es\) alive after TERM\/KILL/, error.message)
    ensure
      reap_child(lingering) if lingering
    end
  end

  def test_entries_that_vanish_before_their_environment_is_read_are_skipped
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      # Process exit races the inventory: the pid is listed but its environ
      # is already gone. That is an ordinary exit, not a cleanup failure.
      write_proc_entry(dir, 424_242, environ: nil)

      assert build_custody(dir).cleanup!
    end
  end

  def test_an_empty_process_environment_is_a_non_match
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      write_proc_entry(dir, 424_242, environ: "")

      assert build_custody(dir).cleanup!
    end
  end

  def test_an_oversized_process_environment_fails_the_cleanup
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      oversized =
        "\0" * (Hive::InvocationProcessCustody::MAX_ENVIRONMENT_BYTES + 1)
      write_proc_entry(dir, 424_242, environ: oversized)

      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        build_custody(dir).cleanup!
      end

      assert_match(/environment exceeds its bound/, error.message)
    end
  end

  def test_an_unreadable_procfs_root_fails_the_cleanup
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")
    skip "root ignores directory permissions" if Process.uid.zero?

    with_tmp_dir do |dir|
      root = File.join(dir, "proc")
      FileUtils.mkdir_p(root)
      File.chmod(0o000, root)
      begin
        error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
          build_custody(root).cleanup!
        end

        assert_match(/procfs is unavailable: Errno::EACCES/, error.message)
      ensure
        File.chmod(0o700, root)
      end
    end
  end

  def test_a_matching_process_that_exits_before_identity_capture_is_skipped
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      reaped = Process.spawn(RbConfig.ruby, "-e", "exit! 0",
                             out: File::NULL, err: File::NULL)
      Process.wait(reaped)
      write_proc_entry(dir, reaped, environ: custody_environ(TOKEN))

      assert build_custody(dir).cleanup!
    end
  end

  def test_cleanup_falls_back_to_the_ps_inventory_without_procfs
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      # macOS/BSD hosts have no procfs; point the custody at an absent root
      # so the `ps xeww` inventory is the only way it can find the process.
      custody = Hive::InvocationProcessCustody.new(
        token: TOKEN, proc_root: File.join(dir, "absent-proc")
      )
      owned = spawn_detached(custody.environment)

      custody.cleanup!

      refute process_alive_with_start?(owned)
    ensure
      terminate_exact(owned) if owned
    end
  end

  def test_an_unusable_ps_inventory_fails_the_cleanup
    with_tmp_dir do |dir|
      custody = Hive::InvocationProcessCustody.new(
        token: TOKEN, proc_root: File.join(dir, "absent-proc")
      )
      unavailable = ->(*) { raise Errno::ENOENT }

      error = with_replaced_singleton_method(Open3, :capture3, unavailable) do
        assert_raises(Hive::InvocationProcessCustody::CleanupError) do
          custody.cleanup!
        end
      end
      assert_match(/ps inventory is unavailable: Errno::ENOENT/, error.message)
    end
  end

  def test_environment_and_process_identity_fail_closed_when_unbounded_or_missing
    Dir.mktmpdir("hive-process-custody-environ") do |dir|
      path = File.join(dir, "environ")
      File.binwrite(path, "x" * (Hive::InvocationProcessCustody::MAX_ENVIRONMENT_BYTES + 1))
      custody = Hive::InvocationProcessCustody.new(token: "e" * 64)

      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        custody.send(:environment_matches?, path)
      end
      assert_match(/environment exceeds its bound/, error.message)

      replacement = ->(*) { nil }
      with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, replacement) do
        alive = ->(*) { true }
        with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, alive) do
          error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
            custody.send(:capture_identity, 4242)
          end
          assert_match(/identity is unavailable for pid 4242/, error.message)
        end
      end
    end
  end

  def test_ps_inventory_validates_availability_status_bounds_and_rows
    custody = Hive::InvocationProcessCustody.new(token: "f" * 64)
    success = Struct.new(:success?).new(true)
    failure = Struct.new(:success?).new(false)

    with_replaced_singleton_method(File, :file?, ->(*) { false }) do
      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        custody.send(:ps_matches)
      end
      assert_match(/ps inventory is unavailable/, error.message)
    end

    replacement = ->(*) { [ "", "no ps", failure ] }
    with_replaced_singleton_method(Open3, :capture3, replacement) do
      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        custody.send(:ps_matches)
      end
      assert_match(/ps inventory failed/, error.message)
    end

    oversized = "2 command\n" * (Hive::InvocationProcessCustody::MAX_PROCESSES + 1)
    replacement = ->(*) { [ oversized, "", success ] }
    with_replaced_singleton_method(Open3, :capture3, replacement) do
      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        custody.send(:ps_matches)
      end
      assert_match(/inventory exceeds its bound/, error.message)
    end

    output = <<~TEXT
      malformed
      1 command #{Hive::InvocationProcessCustody::ENVIRONMENT_KEY}=#{"f" * 64}
      4242 command OTHER=value
      4243 command #{Hive::InvocationProcessCustody::ENVIRONMENT_KEY}=#{"f" * 64}
    TEXT
    replacement = ->(*) { [ output, "", success ] }
    with_replaced_singleton_method(Open3, :capture3, replacement) do
      start_time = ->(*) { "start-4243" }
      with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, start_time) do
        assert_equal(
          [ { pid: 4243, start_time: "start-4243" } ],
          custody.send(:ps_matches)
        )
      end
    end

    replacement = ->(*) { raise Errno::ENOENT }
    with_replaced_singleton_method(Open3, :capture3, replacement) do
      error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
        custody.send(:ps_matches)
      end
      assert_match(/ps inventory is unavailable: Errno::ENOENT/, error.message)
    end
  end

  def test_signal_races_are_ignored_and_permission_failures_are_reported
    custody = Hive::InvocationProcessCustody.new(token: "0" * 64)
    target = { pid: 4242, start_time: "current" }

    current = ->(*) { true }
    with_replaced_singleton_method(Hive::ProcessKill, :captured_process_current?, current) do
      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
        assert_nil custody.send(:signal_current, "TERM", target)
      end

      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
        error = assert_raises(Hive::InvocationProcessCustody::CleanupError) do
          custody.send(:signal_current, "TERM", target)
        end
        assert_match(/cannot signal same-user pid 4242/, error.message)
      end
    end
  end

  def test_a_process_that_exits_before_its_signal_lands_is_not_a_failure
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      entry = write_proc_entry(dir, Process.ppid, environ: custody_environ(TOKEN))
      # The pid dies between the inventory read and the kill(2); the next
      # sweep no longer lists it, which is a completed exit and not an error.
      vanish = ->(_seconds) { FileUtils.rm_rf(entry) }
      custody = Hive::InvocationProcessCustody.new(
        token: TOKEN, proc_root: dir, clock: -> { 0.0 }, sleeper: vanish
      )

      assert with_replaced_singleton_method(
        Process, :kill, signal_raising(Errno::ESRCH)
      ) { custody.cleanup! }
    end
  end

  def test_a_process_that_cannot_be_signalled_fails_the_cleanup
    skip "exact process-custody integration requires Linux procfs" unless
      RUBY_PLATFORM.include?("linux") && File.directory?("/proc")

    with_tmp_dir do |dir|
      write_proc_entry(dir, Process.ppid, environ: custody_environ(TOKEN))
      custody = build_custody(dir)

      error = with_replaced_singleton_method(
        Process, :kill, signal_raising(Errno::EPERM)
      ) do
        assert_raises(Hive::InvocationProcessCustody::CleanupError) do
          custody.cleanup!
        end
      end

      assert_match(/cannot signal same-user pid #{Process.ppid}/, error.message)
    end
  end

  private

  # Fixed so fake procfs environments can name the token they must match.
  TOKEN = "b" * 64

  def build_custody(proc_root)
    Hive::InvocationProcessCustody.new(
      token: TOKEN, proc_root: proc_root,
      clock: advancing_clock, sleeper: ->(_seconds) { }
    )
  end

  # Spend each grace period in a single sweep so the signal ladder does not
  # hold the suite for TERM_GRACE_SECONDS + KILL_GRACE_SECONDS.
  def advancing_clock
    ticks = 0.0
    -> { ticks += 1_000.0 }
  end

  def custody_environ(token)
    "PATH=/usr/bin\0#{Hive::InvocationProcessCustody::ENVIRONMENT_KEY}=#{token}\0"
  end

  def write_proc_entry(root, pid, environ:)
    entry = File.join(root, pid.to_s)
    FileUtils.mkdir_p(entry)
    File.binwrite(File.join(entry, "environ"), environ) if environ
    entry
  end

  # Signal 0 stays real: it is a liveness probe, not a termination request.
  def signal_raising(error_class)
    real_kill = Process.method(:kill)
    lambda do |signal, *pids|
      raise error_class unless signal == 0

      real_kill.call(signal, *pids)
    end
  end

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

  def reap_child(pid)
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(pid)
  end

  def terminate_exact(target)
    return unless process_alive_with_start?(target)

    Process.kill("KILL", target.fetch(:pid))
  rescue Errno::ESRCH
    nil
  end
end
