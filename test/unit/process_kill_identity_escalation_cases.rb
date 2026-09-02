class ProcessKillTest < Minitest::Test
  def test_terminate_process_treats_post_term_identity_io_failure_as_unavailable
    start_times = [ "original", Errno::EIO.new ]
    alive_results = [ true, true ]
    signals = []
    start_time_reader = lambda do |_pid|
      outcome = start_times.shift
      raise outcome if outcome.is_a?(Exception)

      outcome
    end

    with_replaced_singleton_method(Hive::Lock, :process_start_time, start_time_reader) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { alive_results.shift }) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, ->(_pid, _seconds) { false }) do
          with_replaced_singleton_method(Hive::ProcessKill, :safe_kill,
                                         ->(signal, pid) { signals << [ signal, pid ] }) do
            result = Hive::ProcessKill.terminate_process(
              1234, recorded_start_time: "original", grace_seconds: 0
            )

            refute result.killed
            assert_equal "kill_failed", result.skipped_reason
          end
        end
      end
    end

    assert_equal [ [ "TERM", 1234 ] ], signals,
                 "an unavailable post-TERM identity must fail closed without KILL"
    assert_empty start_times
    assert_empty alive_results
  end

  def test_terminate_process_does_not_kill_replacement_after_term_grace
    script = run_scripted_terminate_process(
      start_times: [ "original", "replacement", nil ],
      alive_results: [ true, true, false ],
      wait_results: [ false, false ]
    )

    assert script.fetch(:result).killed
    assert_nil script.fetch(:result).skipped_reason
    assert_equal [
      [ :alive, 1234 ],
      [ :start_time, 1234 ],
      [ :signal, "TERM", 1234 ],
      [ :wait, 1234, 0 ],
      [ :start_time, 1234 ]
    ], script.fetch(:calls)
    assert_equal [ nil ], script.fetch(:remaining).fetch(:start_times),
                 "the replacement decision must be retained without a trailing identity read"
    assert_equal [ true, false ], script.fetch(:remaining).fetch(:alive_results)
    assert_equal [ false ], script.fetch(:remaining).fetch(:wait_results)
  end

  def test_terminate_process_returns_when_matching_process_exits_during_term_grace
    script = run_scripted_terminate_process(
      start_times: [ "original", "must-not-be-read" ],
      alive_results: [ true ],
      wait_results: [ true, false ]
    )

    assert script.fetch(:result).killed
    assert_nil script.fetch(:result).skipped_reason
    assert_equal [
      [ :alive, 1234 ],
      [ :start_time, 1234 ],
      [ :signal, "TERM", 1234 ],
      [ :wait, 1234, 0 ]
    ], script.fetch(:calls)
    assert_equal [ "must-not-be-read" ], script.fetch(:remaining).fetch(:start_times)
    assert_equal [ false ], script.fetch(:remaining).fetch(:wait_results)
  end

  def test_terminate_process_distinguishes_unavailable_identity_from_disappearance_after_term
    cases = [
      { final_alive: false, killed: true, reason: nil },
      { final_alive: true, killed: false, reason: "kill_failed" }
    ]

    cases.each do |test_case|
      script = run_scripted_terminate_process(
        start_times: [ "original", nil ],
        alive_results: [ true, test_case.fetch(:final_alive) ],
        wait_results: [ false ]
      )

      assert_equal test_case.fetch(:killed), script.fetch(:result).killed
      if test_case.fetch(:reason)
        assert_equal test_case.fetch(:reason), script.fetch(:result).skipped_reason
      else
        assert_nil script.fetch(:result).skipped_reason
      end
      assert_equal [
        [ :alive, 1234 ],
        [ :start_time, 1234 ],
        [ :signal, "TERM", 1234 ],
        [ :wait, 1234, 0 ],
        [ :start_time, 1234 ],
        [ :alive, 1234 ]
      ], script.fetch(:calls)
      assert_script_consumed(script)
    end
  end

  def test_terminate_process_classifies_every_post_kill_identity_outcome
    cases = [
      {
        label: "kill wait observes exit",
        start_times: [ "original", "original" ],
        alive_results: [ true ],
        wait_results: [ false, true ],
        killed: true,
        reason: nil
      },
      {
        label: "replacement appears after kill",
        start_times: [ "original", "original", "replacement" ],
        alive_results: [ true ],
        wait_results: [ false, false ],
        killed: true,
        reason: nil
      },
      {
        label: "identity unavailable but pid absent after kill",
        start_times: [ "original", "original", nil ],
        alive_results: [ true, false ],
        wait_results: [ false, false ],
        killed: true,
        reason: nil
      },
      {
        label: "identity unavailable and pid live after kill",
        start_times: [ "original", "original", nil ],
        alive_results: [ true, true ],
        wait_results: [ false, false ],
        killed: false,
        reason: "kill_failed"
      },
      {
        label: "recorded identity survives kill",
        start_times: [ "original", "original", "original" ],
        alive_results: [ true ],
        wait_results: [ false, false ],
        killed: false,
        reason: "kill_failed"
      }
    ]

    cases.each do |test_case|
      script = run_scripted_terminate_process(
        start_times: test_case.fetch(:start_times),
        alive_results: test_case.fetch(:alive_results),
        wait_results: test_case.fetch(:wait_results)
      )

      assert_equal test_case.fetch(:killed), script.fetch(:result).killed, test_case.fetch(:label)
      if test_case.fetch(:reason)
        assert_equal test_case.fetch(:reason), script.fetch(:result).skipped_reason, test_case.fetch(:label)
      else
        assert_nil script.fetch(:result).skipped_reason, test_case.fetch(:label)
      end
      assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signal_calls(script), test_case.fetch(:label)
      assert_script_consumed(script, label: test_case.fetch(:label))
    end
  end

  def test_terminate_process_trusts_unavailable_initial_lookup_before_term
    script = run_scripted_terminate_process(
      start_times: [ nil, "original" ],
      alive_results: [ true ],
      wait_results: [ false, true ]
    )

    assert script.fetch(:result).killed
    assert_nil script.fetch(:result).skipped_reason
    assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signal_calls(script)
    assert_script_consumed(script)
  end

  def test_terminate_process_refuses_scripted_initial_replacement_without_signalling
    script = run_scripted_terminate_process(
      start_times: [ "replacement" ],
      alive_results: [ true ],
      wait_results: []
    )

    refute script.fetch(:result).killed
    assert_equal "pid_reuse_guard", script.fetch(:result).skipped_reason
    assert_empty signal_calls(script)
    assert_script_consumed(script)
  end

  def test_terminate_process_without_recorded_identity_uses_legacy_liveness_escalation
    script = run_scripted_terminate_process(
      recorded_start_time: nil,
      start_times: [],
      alive_results: [ true, true, true ],
      wait_results: [ false, false ]
    )

    refute script.fetch(:result).killed
    assert_equal "kill_failed", script.fetch(:result).skipped_reason
    assert_equal [
      [ :alive, 1234 ],
      [ :signal, "TERM", 1234 ],
      [ :wait, 1234, 0 ],
      [ :alive, 1234 ],
      [ :signal, "KILL", 1234 ],
      [ :wait, 1234, Hive::ProcessKill::KILL_GRACE_SECONDS ],
      [ :alive, 1234 ]
    ], script.fetch(:calls)
    assert_script_consumed(script)
  end

  def test_terminate_process_reports_permission_denied_when_kill_signal_fails
    script = run_scripted_terminate_process(
      start_times: [ "original", "original" ],
      alive_results: [ true ],
      wait_results: [ false ],
      signal_results: [ nil, Errno::EPERM.new ]
    )

    refute script.fetch(:result).killed
    assert_equal "permission_denied", script.fetch(:result).skipped_reason
    assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signal_calls(script)
    assert_script_consumed(script)
  end

  def test_terminate_process_retries_never_signal_a_readable_replacement
    replacement = run_scripted_terminate_process(
      start_times: [ "original", "replacement" ],
      alive_results: [ true ],
      wait_results: [ false ]
    )
    replacement_retry = run_scripted_terminate_process(
      start_times: [ "replacement" ],
      alive_results: [ true ],
      wait_results: []
    )
    ambiguous = run_scripted_terminate_process(
      start_times: [ "original", nil ],
      alive_results: [ true, true ],
      wait_results: [ false ]
    )
    ambiguous_retry = run_scripted_terminate_process(
      start_times: [ "replacement" ],
      alive_results: [ true ],
      wait_results: []
    )

    assert replacement.fetch(:result).killed
    assert_equal [ [ "TERM", 1234 ] ], signal_calls(replacement)
    assert_equal "pid_reuse_guard", replacement_retry.fetch(:result).skipped_reason
    assert_empty signal_calls(replacement_retry)
    assert_equal "kill_failed", ambiguous.fetch(:result).skipped_reason
    assert_equal [ [ "TERM", 1234 ] ], signal_calls(ambiguous)
    assert_equal "pid_reuse_guard", ambiguous_retry.fetch(:result).skipped_reason
    assert_empty signal_calls(ambiguous_retry)
  end


  def test_terminate_process_group_trusts_unavailable_initial_start_time_lookup
    target = { pid: 1234, ppid: 1, pgid: 1234, start_time: "original", depth: 0 }
    identity_reads = []
    signal_calls = []
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, lambda { |pid|
        identity_reads << pid
        nil
      }) do
        with_replaced_singleton_method(Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { [ target ] }) do
          with_replaced_singleton_method(Hive::ProcessKill, :signal_captured_processes,
                                         lambda { |signal, targets, require_identity: false|
                                           signal_calls << [ signal, targets, require_identity ]
                                           false
                                         }) do
            with_replaced_singleton_method(Hive::ProcessKill, :wait_until_process_tree_dead,
                                           ->(_pid, _targets, _seconds) { true }) do
              result = Hive::ProcessKill.terminate_process_group(
                1234, recorded_start_time: "original", grace_seconds: 0
              )

              assert result.killed
              assert_nil result.skipped_reason
            end
          end
        end
      end
    end

    assert_equal [ 1234 ], identity_reads,
                 "the shared initial ownership helper must keep trusting an unavailable lookup"
    assert_equal [ [ "TERM", [ target ], false ] ], signal_calls
  end


  private

  def signal_calls(script)
    script.fetch(:calls).filter_map do |call|
      [ call.fetch(1), call.fetch(2) ] if call.first == :signal
    end
  end

  def assert_script_consumed(script, label: nil)
    remaining = script.fetch(:remaining)
    %i[start_times alive_results wait_results signal_results].each do |name|
      assert_empty remaining.fetch(name), [ label, "unconsumed #{name}" ].compact.join(": ")
    end
  end

  def run_scripted_terminate_process(start_times:, alive_results:, wait_results:,
                                     recorded_start_time: "original", signal_results: [])
    remaining = {
      start_times: start_times.dup,
      alive_results: alive_results.dup,
      wait_results: wait_results.dup,
      signal_results: signal_results.dup
    }
    calls = []
    read_next = lambda do |name|
      values = remaining.fetch(name)
      raise "unexpected #{name.to_s.delete_suffix('_results')} call" if values.empty?

      values.shift
    end
    start_time = lambda do |pid|
      calls << [ :start_time, pid ]
      read_next.call(:start_times)
    end
    alive = lambda do |pid|
      calls << [ :alive, pid ]
      read_next.call(:alive_results)
    end
    wait = lambda do |pid, seconds|
      calls << [ :wait, pid, seconds ]
      read_next.call(:wait_results)
    end
    signal = lambda do |name, pid|
      calls << [ :signal, name, pid ]
      outcome = remaining.fetch(:signal_results).shift
      raise outcome if outcome.is_a?(Exception)
    end

    result = with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, start_time) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, alive) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, wait) do
          with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, signal) do
            Hive::ProcessKill.terminate_process(
              1234, recorded_start_time: recorded_start_time, grace_seconds: 0
            )
          end
        end
      end
    end

    { result: result, calls: calls, remaining: remaining }
  end

end
