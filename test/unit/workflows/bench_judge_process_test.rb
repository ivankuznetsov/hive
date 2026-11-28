require "test_helper"
require "timeout"
require_relative "../../../templates/builtins/bench/runtime/harness/lib/judge_process"

class BenchJudgeProcessTest < Minitest::Test
  Supervisor = HiveBench::JudgeProcess

  def capture(argv, **options)
    Timeout.timeout(10) do
      Supervisor.capture(argv, **{ stdin_data: "", timeout: 3, grace: 0.12, settlement: 0.3 }.merge(options))
    end
  end

  def test_duration_compatibility_and_cleanup_budgets
    assert_equal 5.0, Supervisor::GRACE
    assert_equal 1.0, Supervisor::SETTLEMENT
    { 0 => 0, "0s" => 0, 0.25 => 0.25, "0.5m" => 30, "2h" => 7200, "1d" => 86_400 }.each do |input, seconds|
      assert_equal seconds, Supervisor.seconds(input)
    end
    [ "-1s", -1, "inf", Float::INFINITY, Float::NAN, "1ms", "", nil ].each do |bad|
      assert_raises(ArgumentError) { Supervisor.seconds(bad) }
    end
  end

  def test_bidirectional_io_can_exceed_all_three_pipe_capacities
    script = 'STDERR.write("e" * 200_000); STDOUT.write("o" * 200_000); STDOUT.write(STDIN.read)'
    result = capture([ RbConfig.ruby, "-e", script ], stdin_data: "p" * 200_000, timeout: "0.5m")
    assert_nil result.error
    assert result.status.success?
    assert_equal "o" * 200_000 + "p" * 200_000, result.stdout
    assert_equal "e" * 200_000, result.stderr
    assert result.cleanup.reaped
    assert_empty result.cleanup.signals
  end

  def test_custody_ignores_rubyopt_and_preserves_it_for_the_judge
    result = capture([ "/bin/sh", "-c", 'printf %s "$RUBYOPT"; exit 124' ],
                     timeout: 0, env: { "RUBYOPT" => "-rmissing-bench-library", "PATH" => "" })
    assert_nil result.error
    assert_equal 124, result.status.exitstatus
    refute result.timed_out
    assert_equal "-rmissing-bench-library", result.stdout
  end

  def test_signal_and_missing_executable_are_distinct_from_deadline
    result = capture([ "/bin/sh", "-c", 'kill -TERM "$$"' ])
    assert_nil result.error
    assert_equal Signal.list.fetch("TERM"), result.status.termsig
    refute result.status.success?
    missing = capture([ "/nonexistent/bench-cli" ])
    assert_nil missing.status
    assert_match(/bench-cli.*No such file/i, missing.error)
    refute missing.timed_out
  end
end
