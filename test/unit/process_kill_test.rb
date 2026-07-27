require "test_helper"
require "hive/process_kill"
require "hive/lock"

# Direct unit tests for the security-sensitive PID kill/reuse logic
# in Hive::ProcessKill. Drop covers the happy path incidentally;
# these pin the guard arms (invalid_pid, not_alive, pid_reuse_guard,
# permission_denied, kill_failed) so a regression in any of them
# fails here instead of letting drop signal a foreign PID silently.
class ProcessKillTest < Minitest::Test
  include HiveTestHelper
  def test_terminate_process_refuses_pid_zero_as_invalid
    result = Hive::ProcessKill.terminate_process(0)
    assert_equal 0, result.pid
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason,
                 "PID 0 means current process group to Process.kill; must be rejected before signalling"
  end

  def test_terminate_process_refuses_pid_one_as_invalid
    result = Hive::ProcessKill.terminate_process(1)
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason,
                 "PID 1 is init; must be rejected outright"
  end

  def test_terminate_process_group_refuses_pid_zero_as_invalid
    result = Hive::ProcessKill.terminate_process_group(0)
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason,
                 "PID 0 → negation would target current process group; reject before signalling"
  end

  def test_terminate_process_returns_invalid_pid_for_nil_argument
    result = Hive::ProcessKill.terminate_process(nil)
    assert_nil result.pid
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason
  end

  def test_terminate_process_returns_not_alive_for_dead_pid
    # PID space is finite but a very large number is almost certainly
    # not currently allocated to a live process.
    dead_pid = 999_999
    result = Hive::ProcessKill.terminate_process(dead_pid)
    refute result.killed
    assert_equal "not_alive", result.skipped_reason
  end

  def test_terminate_process_pid_reuse_guard_when_start_time_does_not_match
    # Use the current PID so it's definitely alive, but record a fake
    # start-time so the guard rejects rather than signalling.
    result = Hive::ProcessKill.terminate_process(
      Process.pid, recorded_start_time: "definitely-not-this-process"
    )
    refute result.killed, "must not signal ourselves when start-time guard fails"
    assert_equal "pid_reuse_guard", result.skipped_reason
  end

  def test_pid_owned_by_recorded_start_returns_true_when_recorded_start_time_blank
    # Empty recorded → trust the recorded pid (only path that lets a
    # legitimate kill proceed when start-time isn't pinned).
    assert Hive::ProcessKill.pid_owned_by_recorded_start?(Process.pid, "")
    assert Hive::ProcessKill.pid_owned_by_recorded_start?(Process.pid, nil)
  end

  def test_pid_owned_by_recorded_start_returns_true_when_live_lookup_yields_blank
    # When the live start-time lookup fails (containerised /proc, etc.)
    # the guard falls through to trust-the-recorded-pid so legitimate
    # cleanup still works. Stub the lookup to return nil.
    with_process_start_time_stub(nil) do
      assert Hive::ProcessKill.pid_owned_by_recorded_start?(
        Process.pid, "some-recorded-start-time"
      )
    end
  end

  def test_pid_owned_by_recorded_start_returns_false_when_start_times_diverge
    with_process_start_time_stub("live-start-time") do
      refute Hive::ProcessKill.pid_owned_by_recorded_start?(
        Process.pid, "different-recorded-time"
      )
    end
  end

  def test_valid_target_pid_predicate_rejects_zero_one_and_non_integers
    refute Hive::ProcessKill.valid_target_pid?(0)
    refute Hive::ProcessKill.valid_target_pid?(1)
    refute Hive::ProcessKill.valid_target_pid?(-1)
    refute Hive::ProcessKill.valid_target_pid?(nil)
    refute Hive::ProcessKill.valid_target_pid?("123")
    assert Hive::ProcessKill.valid_target_pid?(2)
    assert Hive::ProcessKill.valid_target_pid?(999_999)
  end

  # Spawn a real child, let it terminate, then verify terminate_process
  # reports killed=true with no skipped_reason.
  def test_terminate_process_kills_a_real_short_lived_child
    pid = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
    begin
      result = Hive::ProcessKill.terminate_process(pid, grace_seconds: 1.0)
      assert_equal pid, result.pid
      assert result.killed, "real child must be killed by SIGTERM/SIGKILL escalation"
      assert_nil result.skipped_reason
    ensure
      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        # already reaped
      end
    end
  end

  def test_terminate_process_group_kills_recursive_descendants_that_ignore_term
    with_tmp_dir do |dir|
      wrapper_pid_path = File.join(dir, "wrapper.pid")
      grandchild_pid_path = File.join(dir, "grandchild.pid")
      grandchild_term_path = File.join(dir, "grandchild.term")
      root_pid = Process.spawn(
        RbConfig.ruby, "-e", <<~'RUBY', wrapper_pid_path, grandchild_pid_path, grandchild_term_path,
          wrapper = Process.spawn(
            RbConfig.ruby, "-e", <<~'CHILD', ARGV.fetch(1), ARGV.fetch(2),
              grandchild = Process.spawn(
                RbConfig.ruby, "-e", <<~'GRANDCHILD', ARGV.fetch(0), ARGV.fetch(1),
                  trap("TERM") { File.write(ARGV.fetch(1), "received") }
                  File.write(ARGV.fetch(0), Process.pid)
                  sleep 30
                GRANDCHILD
                pgroup: true, out: File::NULL, err: File::NULL
              )
              Process.wait(grandchild)
            CHILD
            out: File::NULL, err: File::NULL
          )
          File.write(ARGV.fetch(0), wrapper)
          sleep 30
        RUBY
        pgroup: true, out: File::NULL, err: File::NULL
      )
      wrapper_pid = wait_for_pid_file(wrapper_pid_path)
      grandchild_pid = wait_for_pid_file(grandchild_pid_path)

      assert_equal root_pid, Process.getpgid(wrapper_pid), "wrapper must remain in the root process group"
      assert_equal grandchild_pid, Process.getpgid(grandchild_pid), "grandchild must create a nested process group"

      result = Hive::ProcessKill.terminate_process_group(root_pid, grace_seconds: 0.2)

      assert result.killed, "the recorded root process must be terminated"
      assert File.exist?(grandchild_term_path), "grandchild must receive and ignore TERM before KILL escalation"
      refute process_alive?(grandchild_pid), "a recursive tool subprocess must not survive the recorded agent"
    ensure
      [ grandchild_pid, wrapper_pid, root_pid ].compact.each { |pid| kill_process_if_alive(pid) }
      begin
        Process.waitpid(root_pid, Process::WNOHANG) if root_pid
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def test_pid_alive_treats_permission_denied_as_alive
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| raise Errno::EPERM }) do
      assert Hive::ProcessKill.pid_alive?(1234)
    end
  end

  def test_process_start_time_returns_nil_for_malformed_pid
    assert_nil Hive::ProcessKill.process_start_time("not-a-pid")
  end

  def test_terminate_process_escalates_to_kill_when_term_does_not_stop_process
    alive_sequence = [ true, true, false ]
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| alive_sequence.shift }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |signal, pid| signals << [ signal, pid ] }) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, lambda { |_pid, _seconds| false }) do
          result = Hive::ProcessKill.terminate_process(1234, grace_seconds: 0)

          assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signals
          assert result.killed
          assert_nil result.skipped_reason
        end
      end
    end
  end

  def test_terminate_process_reports_permission_denied_when_signal_fails
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |_signal, _pid| raise Errno::EPERM }) do
        result = Hive::ProcessKill.terminate_process(1234, grace_seconds: 0)

        refute result.killed
        assert_equal "permission_denied", result.skipped_reason
      end
    end
  end

  def test_terminate_process_group_pid_reuse_guard_when_start_time_does_not_match
    with_process_start_time_stub("live-start-time") do
      result = Hive::ProcessKill.terminate_process_group(
        Process.pid, recorded_start_time: "different-recorded-time"
      )

      refute result.killed
      assert_equal "pid_reuse_guard", result.skipped_reason
    end
  end

  def test_terminate_process_group_returns_invalid_pid_for_nil_argument
    result = Hive::ProcessKill.terminate_process_group(nil)

    assert_nil result.pid
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason
  end

  def test_terminate_process_group_escalates_to_kill_when_term_does_not_stop_process
    target = { pid: 1234, ppid: 1, pgid: 1234, start_time: "original", depth: 0 }
    signal_calls = []
    wait_results = [ false, true ]
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { [ target ] }) do
        with_replaced_singleton_method(Hive::ProcessKill, :signal_captured_processes,
                                       lambda { |signal, targets, require_identity: false|
                                         signal_calls << [ signal, targets, require_identity ]
                                         false
                                       }) do
          with_replaced_singleton_method(Hive::ProcessKill, :wait_until_process_tree_dead,
                                         ->(_pid, _targets, _seconds) { wait_results.shift }) do
            with_process_start_time_stub("original") do
              result = Hive::ProcessKill.terminate_process_group(1234, grace_seconds: 0)

              assert_equal [
                [ "TERM", [ target ], false ],
                [ "KILL", [ target ], true ]
              ], signal_calls
              assert result.killed
              assert_nil result.skipped_reason
            end
          end
        end
      end
    end
  end

  def test_terminate_process_group_reports_not_alive_when_group_disappears
    alive_results = [ true, false ]
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| alive_results.shift }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { [] }) do
        result = Hive::ProcessKill.terminate_process_group(1234, grace_seconds: 0)

        refute result.killed
        assert_equal "not_alive", result.skipped_reason
      end
    end
  end

  def test_terminate_process_group_reports_permission_denied_when_signal_fails
    target = { pid: 1234, ppid: 1, pgid: 1234, start_time: "original", depth: 0 }
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { [ target ] }) do
        with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |_signal, _target| raise Errno::EPERM }) do
          with_replaced_singleton_method(Hive::ProcessKill, :wait_until_process_tree_dead,
                                         ->(_pid, _targets, _seconds) { false }) do
            with_process_start_time_stub("original") do
              result = Hive::ProcessKill.terminate_process_group(1234, grace_seconds: 0)

              refute result.killed
              assert_equal "permission_denied", result.skipped_reason
            end
          end
        end
      end
    end
  end

  def test_process_tree_snapshot_and_signalling_order_descendants_first
    table = {
      1001 => { ppid: 1, pgid: 1001 },
      1002 => { ppid: 1001, pgid: 1001 },
      1003 => { ppid: 1002, pgid: 1003 }
    }
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :process_table, -> { table }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(pid) { "start-#{pid}" }) do
        targets = Hive::ProcessKill.process_tree_snapshot(1001)

        assert_equal [ 1003, 1002, 1001 ], targets.map { |target| target.fetch(:pid) }
        with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                       lambda { |signal, pid| signals << [ signal, pid ] }) do
          refute Hive::ProcessKill.signal_captured_processes("TERM", targets)
        end
      end
    end

    assert_equal [ [ "TERM", 1003 ], [ "TERM", 1002 ], [ "TERM", 1001 ] ], signals
  end

  def test_terminate_process_group_skips_pid_reused_between_ancestry_and_identity_reads
    first = [
      { pid: 2002, ppid: 2001, pgid: 2002, start_time: "replacement", depth: 1 },
      { pid: 2001, ppid: 1, pgid: 2001, start_time: "root", depth: 0 }
    ]
    confirmation = [
      { pid: 2001, ppid: 1, pgid: 2001, start_time: "root", depth: 0 }
    ]
    snapshots = [ first, confirmation ]
    signals = []

    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { snapshots.shift }) do
        with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(_pid) { "root" }) do
          with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                         ->(signal, pid) { signals << [ signal, pid ] }) do
            with_replaced_singleton_method(Hive::ProcessKill, :wait_until_process_tree_dead,
                                           ->(_pid, _targets, _seconds) { true }) do
              result = Hive::ProcessKill.terminate_process_group(
                2001, recorded_start_time: "root", grace_seconds: 0
              )

              assert result.killed
            end
          end
        end
      end
    end

    assert_equal [ [ "TERM", 2001 ] ], signals,
                 "a replacement PID whose ancestry changed must not receive TERM"
  end

  def test_process_tree_unavailable_on_nonzero_ps_exit_still_attempts_root_cleanup
    status = Object.new
    status.define_singleton_method(:success?) { false }
    assert_process_tree_failure_reports_unavailable(->(*_args) { [ "", "ps failed", status ] })
  end

  def test_process_tree_unavailable_on_ps_system_error_still_attempts_root_cleanup
    assert_process_tree_failure_reports_unavailable(->(*_args) { raise Errno::ENOENT })
  end

  def test_empty_process_tree_with_live_root_attempts_root_cleanup
    cleanup = []
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { [] }) do
        with_replaced_singleton_method(Hive::ProcessKill, :best_effort_terminate_root,
                                       ->(*args) { cleanup << args }) do
          result = Hive::ProcessKill.terminate_process_group(4321, grace_seconds: 0.25)

          refute result.killed
          assert_equal "process_tree_unavailable", result.skipped_reason
        end
      end
    end

    assert_equal [ [ 4321, nil, 0.25 ] ], cleanup
  end

  def test_process_tree_confirmation_failure_attempts_root_cleanup
    target = { pid: 4321, ppid: 1, pgid: 4321, start_time: "root", depth: 0 }
    snapshots = [ [ target ], nil ]
    cleanup = []
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { snapshots.shift }) do
        with_replaced_singleton_method(Hive::ProcessKill, :best_effort_terminate_root,
                                       ->(*args) { cleanup << args }) do
          result = Hive::ProcessKill.terminate_process_group(4321, grace_seconds: 0.25)

          refute result.killed
          assert_equal "process_tree_unavailable", result.skipped_reason
        end
      end
    end

    assert_equal [ [ 4321, nil, 0.25 ] ], cleanup
  end

  def test_process_tree_confirmation_refuses_reused_root
    target = { pid: 4321, ppid: 1, pgid: 4321, start_time: "old", depth: 0 }
    replacement = target.merge(ppid: 99, start_time: "replacement")
    snapshots = [ [ target ], [ replacement ] ]
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_owned_by_recorded_start?, ->(*) { true }) do
        with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { snapshots.shift }) do
          result = Hive::ProcessKill.terminate_process_group(4321, grace_seconds: 0)

          refute result.killed
          assert_equal "pid_reuse_guard", result.skipped_reason
        end
      end
    end
  end

  def test_process_tree_confirmation_checks_recorded_root_identity_again
    target = { pid: 4321, ppid: 1, pgid: 4321, start_time: "replacement", depth: 0 }
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_owned_by_recorded_start?, ->(*) { true }) do
        with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { [ target ] }) do
          result = Hive::ProcessKill.terminate_process_group(
            4321, recorded_start_time: "original", grace_seconds: 0
          )

          refute result.killed
          assert_equal "pid_reuse_guard", result.skipped_reason
        end
      end
    end
  end

  def test_terminate_process_group_treats_disappearing_snapshot_as_not_alive
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot,
                                     ->(_pid) { raise Errno::ESRCH }) do
        result = Hive::ProcessKill.terminate_process_group(4321, grace_seconds: 0)

        refute result.killed
        assert_equal "not_alive", result.skipped_reason
      end
    end
  end

  def test_process_table_invokes_an_absolute_trusted_ps_path
    command = nil
    status = Object.new
    status.define_singleton_method(:success?) { true }
    with_system_ps_available do
      with_replaced_singleton_method(Open3, :capture3, lambda { |*args|
        command = args
        [ "4321 1 4321\n", "", status ]
      }) do
        assert_equal({ 4321 => { ppid: 1, pgid: 4321 } }, Hive::ProcessKill.process_table)
      end
    end

    assert_equal Hive::ProcessKill::SYSTEM_PS_PATHS.first, command.first
    assert command.first.start_with?("/"), "process discovery must not resolve ps through PATH"
    refute_equal "ps", command.first
    assert_equal [ "-axo", "pid=,ppid=,pgid=" ], command.drop(1)
  end

  def test_process_table_returns_nil_when_no_trusted_ps_exists
    with_replaced_singleton_method(File, :file?, ->(_path) { false }) do
      assert_nil Hive::ProcessKill.process_table
    end
  end

  def test_process_table_rejects_nonnumeric_rows
    status = Object.new
    status.define_singleton_method(:success?) { true }
    with_system_ps_available do
      with_replaced_singleton_method(Open3, :capture3, ->(*_args) { [ "pid 1 1\n", "", status ] }) do
        assert_nil Hive::ProcessKill.process_table
      end
    end
  end

  def test_malformed_nonblank_ps_row_makes_the_whole_process_tree_unavailable
    status = Object.new
    status.define_singleton_method(:success?) { true }
    capture3 = lambda do |*_args|
      [ "4321 1 4321\nmalformed row\n9999 4321 9999\n", "", status ]
    end

    with_system_ps_available do
      with_replaced_singleton_method(Open3, :capture3, capture3) do
        assert_nil Hive::ProcessKill.process_table,
                   "a partial process snapshot is unsafe when even one nonblank row is malformed"
      end
      assert_process_tree_failure_reports_unavailable(capture3)
    end
  end

  def test_kill_skips_captured_pid_when_identity_changed
    targets = [
      { pid: 2002, ppid: 2001, pgid: 2002, start_time: "original-child", depth: 1 },
      { pid: 2001, ppid: 1, pgid: 2001, start_time: "original-root", depth: 0 }
    ]
    signals = []
    live_starts = { 2002 => "reused-child", 2001 => "original-root" }
    with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(pid) { live_starts.fetch(pid) }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                     lambda { |signal, pid| signals << [ signal, pid ] }) do
        refute Hive::ProcessKill.signal_captured_processes("KILL", targets, require_identity: true)
      end
    end

    assert_equal [ [ "KILL", 2001 ] ], signals,
                 "a PID reused during the TERM grace period must never receive KILL"
  end

  def test_permission_denied_for_one_captured_target_does_not_skip_later_targets
    targets = [
      { pid: 3003, ppid: 3002, pgid: 3003, start_time: "three", depth: 2 },
      { pid: 3002, ppid: 3001, pgid: 3001, start_time: "two", depth: 1 },
      { pid: 3001, ppid: 1, pgid: 3001, start_time: "one", depth: 0 }
    ]
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :captured_process_current?,
                                   ->(_target, require_identity: false) { !require_identity }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |signal, pid|
        signals << [ signal, pid ]
        raise Errno::EPERM if pid == 3003
      }) do
        assert Hive::ProcessKill.signal_captured_processes("TERM", targets)
      end
    end

    assert_equal [ [ "TERM", 3003 ], [ "TERM", 3002 ], [ "TERM", 3001 ] ], signals
  end

  def test_safe_kill_ignores_missing_targets
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _target| raise Errno::ESRCH }) do
      assert_nil Hive::ProcessKill.safe_kill("TERM", 1234)
    end
  end

  def test_safe_kill_propagates_permission_denied
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _target| raise Errno::EPERM }) do
      assert_raises(Errno::EPERM) { Hive::ProcessKill.safe_kill("TERM", 1234) }
    end
  end

  def test_best_effort_root_cleanup_refuses_reused_pid_before_term
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(_pid) { "replacement" }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                     ->(signal, pid) { signals << [ signal, pid ] }) do
        Hive::ProcessKill.best_effort_terminate_root(1234, "original", 0)
      end
    end

    assert_empty signals
  end

  def test_best_effort_root_cleanup_terms_and_kills_same_pid
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(_pid) { "original" }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, ->(_pid, _seconds) { false }) do
          with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                         ->(signal, pid) { signals << [ signal, pid ] }) do
            Hive::ProcessKill.best_effort_terminate_root(1234, "original", 0)
          end
        end
      end
    end

    assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signals
  end

  def test_best_effort_root_cleanup_never_kills_without_identity
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(_pid) { nil }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, ->(_pid, _seconds) { false }) do
          with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                         ->(signal, pid) { signals << [ signal, pid ] }) do
            Hive::ProcessKill.best_effort_terminate_root(1234, nil, 0)
          end
        end
      end
    end

    assert_equal [ [ "TERM", 1234 ] ], signals
  end

  def test_best_effort_root_cleanup_handles_permission_denied_during_kill
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(_pid) { "original" }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, ->(_pid, _seconds) { false }) do
          with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |signal, pid|
            signals << [ signal, pid ]
            raise Errno::EPERM if signal == "KILL"
          }) do
            assert_nil Hive::ProcessKill.best_effort_terminate_root(1234, "original", 0)
          end
        end
      end
    end

    assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signals
  end

  def test_best_effort_root_cleanup_handles_permission_denied_during_term
    with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, ->(_pid) { "original" }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                     ->(_signal, _pid) { raise Errno::EPERM }) do
        assert_nil Hive::ProcessKill.best_effort_terminate_root(1234, "original", 0)
      end
    end
  end

  def test_wait_until_dead_checks_final_state_after_deadline
    with_replaced_singleton_method(Hive::ProcessKill, :reap_if_child_exited, lambda { |_pid| false }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| false }) do
        assert Hive::ProcessKill.wait_until_dead(1234, 0)
      end
    end
  end

  def test_wait_until_dead_polls_until_a_live_process_exits
    alive = [ true, false ]
    with_replaced_singleton_method(Hive::ProcessKill, :reap_if_child_exited, ->(_pid) { false }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { alive.shift }) do
        assert Hive::ProcessKill.wait_until_dead(1234, 1)
      end
    end

    assert_empty alive
  end

  def test_reap_if_child_exited_returns_false_for_non_child
    refute Hive::ProcessKill.reap_if_child_exited(999_999)
  end


  private

  def wait_for_pid_file(path, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    contents = ""
    loop do
      contents = File.read(path) if File.exist?(path)
      break if contents.match?(/\A[0-9]+\z/)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
    flunk "timed out waiting #{timeout}s for child pid file #{File.basename(path)}" unless contents.match?(/\A[0-9]+\z/)

    Integer(contents)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def kill_process_if_alive(pid)
    Process.kill("KILL", pid) if process_alive?(pid)
  rescue Errno::ESRCH
    nil
  end

  def assert_process_tree_failure_reports_unavailable(capture3_replacement)
    root_cleanup_calls = []
    with_replaced_singleton_method(Open3, :capture3, capture3_replacement) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
        with_replaced_singleton_method(Hive::ProcessKill, :best_effort_terminate_root,
                                       lambda { |*args| root_cleanup_calls << args }) do
          result = Hive::ProcessKill.terminate_process_group(4321, grace_seconds: 0.25)

          refute result.killed
          assert_equal "process_tree_unavailable", result.skipped_reason
        end
      end
    end
    assert_equal [ [ 4321, nil, 0.25 ] ], root_cleanup_calls
  end

  def with_system_ps_available
    trusted_paths = Hive::ProcessKill::SYSTEM_PS_PATHS
    with_replaced_singleton_method(File, :file?, ->(path) { trusted_paths.include?(path) }) do
      with_replaced_singleton_method(File, :executable?, ->(path) { trusted_paths.include?(path) }) do
        yield
      end
    end
  end

  # Temporarily replace ProcessKill.process_start_time so we can pin
  # the pid-reuse-guard branches deterministically. Restores the
  # original singleton method on exit.
  def with_process_start_time_stub(value)
    mod = Hive::ProcessKill.singleton_class
    original = mod.instance_method(:process_start_time)
    mod.send(:define_method, :process_start_time) { |_pid| value }
    yield
  ensure
    mod.send(:define_method, :process_start_time, original) if original
  end
end
