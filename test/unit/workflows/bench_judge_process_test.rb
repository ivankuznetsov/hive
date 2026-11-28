require "test_helper"
require "timeout"
require_relative "../../../templates/builtins/bench/runtime/harness/lib/judge_process"

class BenchJudgeProcessTest < Minitest::Test
  include HiveTestHelper

  Supervisor = HiveBench::JudgeProcess
  Fixture = File.expand_path("../../support/bench_judge_fixture.rb", __dir__)
  FixtureArgv = [ RbConfig.ruby, "--disable=gems,rubyopt", Fixture ].freeze

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def with_fixture(mode)
    Dir.mktmpdir("bench-judge-fixture") do |root|
      # Open readers before writers. One stop writer belongs to this test,
      # and only the named process ever opens its liveness FIFO for writing.
      readers = {}
      %w[stop child.live judge.live worker.live].each do |name|
        path = File.join(root, name)
        File.mkfifo(path, 0o600)
        readers[name] = File.open(path, File::RDONLY | File::NONBLOCK)
      end
      writer = File.open(File.join(root, "stop"), File::WRONLY | File::NONBLOCK)
      readers["stop_writer"] = writer
      Timeout.timeout(15) do
        yield root, { "FIXTURE_ROOT" => root, "FIXTURE_MODE" => mode }, readers
      end
    ensure
      writer&.close
      readers&.each_value(&:close)
    end
  end

  def await_file(path)
    Timeout.timeout(3) { sleep 0.005 until File.file?(path) && File.size?(path) }
  end

  def assert_exited(root, pipes, role, within: 1)
    await_file(File.join(root, "#{role}.ready"))
    pipe = pipes.fetch("#{role}.live")
    assert IO.select([ pipe ], nil, nil, within), "#{role} still holds its liveness pipe"
    assert_nil pipe.read_nonblock(1, exception: false)
  end

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

  def test_blocked_stdin_and_continuous_output_obey_the_same_deadline
    %w[blocked flood closed].each do |mode|
      with_fixture(mode) do |root, env, pipes|
        started = now
        result = capture(FixtureArgv, env: env, stdin_data: "p" * 500_000, timeout: 0.6)
        assert result.timed_out
        assert_operator now - started, :<, 1.8
        assert_includes result.stdout, '"score":9'
        if mode == "flood"
          assert_operator result.stdout.bytesize, :>, 65_536
          assert_operator result.stderr.bytesize, :>, 65_536
        end
        assert_exited(root, pipes, "judge")
        assert_exited(root, pipes, "child") if mode == "closed"
      end
    end
  end

  def test_deadline_after_judge_exit_escalates_for_an_orphan_holding_output
    with_fixture("orphan") do |root, env, pipes|
      result = capture(FixtureArgv, env: env, timeout: 0.6)
      assert result.status.success?
      assert result.timed_out
      assert_equal %w[TERM KILL], result.cleanup.signals.keys
      assert result.cleanup.stdout_eof
      assert result.cleanup.stderr_eof
      assert result.cleanup.reaped
      assert_path_exists File.join(root, "child.term")
      assert_exited(root, pipes, "child")
    end
  end

  def test_term_exiting_judge_does_not_shorten_default_grace_for_resistant_child
    with_fixture("family") do |root, env, pipes|
      observer = Thread.new do
        await_file(File.join(root, "child.ready"))
        IO.select([ pipes.fetch("child.live") ], nil, nil, 9)
        now
      end
      started = now
      result = Supervisor.capture(FixtureArgv, env: env, stdin_data: "", timeout: 0.7)
      assert result.timed_out
      assert_equal %w[TERM KILL], result.cleanup.signals.keys
      assert_operator now - started, :<, 7.5
      assert_operator observer.value - Float(File.read(File.join(root, "child.term"))), :>=, 4.8
      assert_exited(root, pipes, "judge")
      assert_exited(root, pipes, "child")
    ensure
      observer&.kill&.join
    end
  end

  def test_normal_release_allows_a_closed_output_helper_to_finish_after_return
    with_fixture("helper") do |root, env, pipes|
      result = capture(FixtureArgv, env: env, timeout: 1)
      assert_nil result.error
      assert result.status.success?
      assert_empty result.cleanup.limitations
      await_file(File.join(root, "child.ready"))
      assert_equal :wait_readable, pipes.fetch("child.live").read_nonblock(1, exception: false)
      File.write(File.join(root, "finish"), "go")
      assert_exited(root, pipes, "child")
      assert_equal "ok", File.read(File.join(root, "finished"))
    end
  end

  def test_partial_score_and_quota_text_never_escape_as_adapter_results
    harness = File.join(File.dirname(Supervisor::WORKER), "..")
    require File.join(harness, "lib/claude_judge")
    require File.join(harness, "lib/codex_judge")
    [ HiveBench::ClaudeJudge, HiveBench::CodexJudge ].each do |adapter|
      with_fixture("quota") do |root, env, pipes|
        fake = File.join(root, "judge")
        File.write(fake, "#!#{RbConfig.ruby}\nrequire #{Fixture.inspect}\nBenchJudgeFixture.run(ENV.fetch('FIXTURE_ROOT'), 'quota')\n")
        File.chmod(0o755, fake)
        original = Supervisor.method(:capture)
        shorter_grace = ->(*args, **options) { original.call(*args, **options, grace: 0.12, settlement: 0.3) }
        with_replaced_singleton_method(Supervisor, :capture, shorter_grace) do
          with_env(env.merge("PATH" => root)) do
            error = assert_raises(adapter::Error) { adapter.judge_fn(bin: fake, timeout_s: 0.7).call(prompt: "score", seed: 0) }
            assert_includes error.message, "timed out after 0.7s"
            assert_includes error.message, "descendant termination unconfirmed"
          end
        end
        assert_exited(root, pipes, "judge")
      end
    end
  end

  def test_split_utf8_banner_preserves_the_capture_encoding
    # A one-byte read forces the two bytes of the reset banner separator to
    # arrive in different reads irrespective of the platform's pipe capacity.
    chunk = Supervisor.send(:remove_const, :CHUNK)
    Supervisor.const_set(:CHUNK, 1)
    banner = "You've hit your session limit · resets 7:40pm (Europe/London)"
    result = capture([ "/bin/sh", "-c", 'printf "%s" "$1"; exit 1', "judge", banner ])
    assert_equal banner, result.stdout
    assert_equal Encoding.default_external, result.stdout.encoding
    require_relative "../../../templates/builtins/bench/runtime/harness/lib/claude_judge"
    assert_equal banner, HiveBench::ClaudeJudge.trusted_limit_detail(out: result.stdout, err: result.stderr)
  ensure
    Supervisor.send(:remove_const, :CHUNK)
    Supervisor.const_set(:CHUNK, chunk)
  end

  def test_repeated_captures_close_every_new_local_io
    before = ObjectSpace.each_object(IO).reject(&:closed?)
    8.times { assert capture([ "/bin/sh", "-c", "exit 0" ]).status.success? }
    after = ObjectSpace.each_object(IO).reject(&:closed?)
    assert_empty after - before
  end

  # This disposable harness has its own caller stdio. The test retains its
  # direct child unreaped across every signal (including teardown).
  def with_harness(env, timeout:, grace:, settlement:)
    input, commands = IO.pipe
    stdout, output = IO.pipe
    stderr, error = IO.pipe
    script = <<~'CODE'
      require ARGV.shift
      Thread.new { exit!(0) if STDIN.gets }
      timeout, grace, settlement, *argv = ARGV
      HiveBench::JudgeProcess.capture(argv, stdin_data: "", timeout: timeout, grace: grace, settlement: settlement)
    CODE
    supervisor = File.join(File.dirname(Supervisor::WORKER), "judge_process")
    pid = Process.spawn(env, RbConfig.ruby, "--disable=gems,rubyopt", "-e", script, supervisor,
                        timeout.to_s, grace.to_s, settlement.to_s, *FixtureArgv, in: input, out: output, err: error)
    [ input, output, error ].each(&:close)
    yield pid, commands, stdout, stderr
  ensure
    kill_and_reap(pid) if pid
    [ input, commands, stdout, output, stderr, error ].compact.each(&:close)
  end

  def kill_and_reap(pid)
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      # Already exited, still our unreaped direct child.
    end
    Timeout.timeout(3) { Process.waitpid(pid) }
  end

  def test_custody_cleans_up_on_harness_sigkill_and_unexpected_normal_exit_even_without_deadline
    %w[kill exit].each do |ending|
      with_fixture("family") do |root, env, pipes|
        with_harness(env, timeout: 0, grace: 0.45, settlement: 0.25) do |pid, commands, stdout, stderr|
          await_file(File.join(root, "child.ready"))
          ending == "kill" ? Process.kill("KILL", pid) : commands.puts("exit")
          [ stdout, stderr ].each do |pipe|
            assert IO.select([ pipe ], nil, nil, 0.3), "custody inherited caller stdio"
            assert_nil pipe.read_nonblock(1, exception: false)
          end
          assert_exited(root, pipes, "child", within: 1.3)
          assert_path_exists File.join(root, "child.term")
          assert_exited(root, pipes, "judge")
        end
      end
    end
  end

  def test_parent_death_during_grace_does_not_reset_the_kill_deadline
    with_fixture("family") do |root, env, pipes|
      with_harness(env, timeout: 0.7, grace: 1.4, settlement: 0.3) do |pid, *|
        await_file(File.join(root, "child.term"))
        sleep 0.9
        Process.kill("KILL", pid)
        assert_exited(root, pipes, "child", within: 0.9)
      end
    end
  end

  def test_custody_backstop_when_harness_is_stopped_with_open_control_pipe
    with_fixture("family") do |root, env, pipes|
      with_harness(env, timeout: 0.8, grace: 0.3, settlement: 0.2) do |pid, *|
        await_file(File.join(root, "child.ready"))
        Process.kill("STOP", pid)
        assert_exited(root, pipes, "child", within: 2.2)
        term_at = Float(File.read(File.join(root, "child.term")))
        assert_operator term_at - Float(File.read(File.join(root, "child.ready"))), :>, 0.8
        assert_exited(root, pipes, "judge")
      end
    end
  end

  def test_worker_loses_report_reader_before_start_or_while_reporting_judge_exit
    %w[before_start after_start].each do |phase|
      with_fixture("orphan") do |root, env, pipes|
        control, commands = IO.pipe
        events, reports = IO.pipe
        null = File.open(File::NULL, "r+")
        events.close if phase == "before_start"
        pid = Process.spawn(env, RbConfig.ruby, "--disable=gems,rubyopt", Supervisor::WORKER, "none", "0.12", "0.3",
                            *FixtureArgv, 3 => control, 4 => reports, 5 => null, 6 => null, 7 => null,
                            in: null, out: null, err: null, pgroup: true)
        [ control, reports, null ].each(&:close)
        if phase == "after_start"
          assert_equal "ready #{pid}\n", Timeout.timeout(1) { events.gets }
          events.close
          commands.puts("start")
          assert_exited(root, pipes, "child")
        end
        _, status = Timeout.timeout(2) { Process.waitpid2(pid) }
        pid = nil
        assert_equal Signal.list.fetch("KILL"), status.termsig
        refute_path_exists File.join(root, "judge.ready") if phase == "before_start"
      ensure
        kill_and_reap(pid) if pid
        [ control, commands, events, reports, null ].compact.each(&:close)
      end
    end
  end

  # Substitute a misbehaving custody executable without changing the judge
  # capture API. Its process still has a real, test-owned group and lifeline.
  def with_worker(root, body)
    path = File.join(root, "custody.rb")
    File.write(path, <<~RUBY + body)
      require #{Fixture.inspect}
      BenchJudgeFixture.watch(ENV.fetch("FIXTURE_ROOT"), "worker")
      control = IO.for_fd(3)
      events = IO.for_fd(4)
      events.sync = true
      (5..7).each { |fd| IO.for_fd(fd).close }
    RUBY
    spawn = Process.method(:spawn)
    replacement = lambda do |*args|
      index = args.index(Supervisor::WORKER)
      args[index] = path if index
      spawn.call(*args)
    end
    with_replaced_singleton_method(Process, :spawn, replacement) { yield }
  end

  def test_missing_or_contradictory_readiness_withholds_all_group_signals
    [ "exit!(1)", 'events.puts("ready #{Process.pid + 1}"); control.read' ].each do |body|
      with_fixture("blocked") do |root, env, _|
        with_worker(root, body) do
          with_replaced_singleton_method(Process, :kill, ->(*) { raise "signalled without custody" }) do
            result = capture(FixtureArgv, env: env)
            assert_match(/custody/, result.error)
            assert_includes result.cleanup.limitations, "group signalling withheld: custody unverified"
            assert_empty result.cleanup.signals
          end
        end
      end
    end
  end

  def test_unexpected_worker_death_and_permission_failure_report_cleanup_limits
    with_fixture("blocked") do |root, env, _|
      with_worker(root, 'events.puts("ready #{Process.pid}"); control.gets; exit!(1)') do
        with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
          result = capture(FixtureArgv, env: env)
          assert_match(/custody exited/, result.error)
          assert_equal({ "TERM" => "Errno::EPERM", "KILL" => "Errno::EPERM" }, result.cleanup.signals)
          assert_match(/group KILL.*permitted/, result.failure_message("claude", 3))
          assert result.cleanup.reaped
        end
      end
    end
  end

  def test_partial_delivery_and_simulated_reuse_after_reap
    with_fixture("blocked") do |root, env, pipes|
      # Emulate an OS delivering each group signal only to the custodian.
      # The real same-group judge closes its output and survives both signals.
      body = <<~'CODE'
        Signal.trap("TERM") {}
        events.puts("ready #{Process.pid}")
        control.gets
        Process.spawn(*ARGV.drop(3), in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
        sleep
      CODE
      with_worker(root, body) do
        events = []
        kill = Process.method(:kill)
        wait = Process.method(:waitpid2)
        selective_delivery = lambda do |signal, group|
          raise "expected owned group" unless group.negative?
          raise "signal after possible identity reuse" if events.include?(:reap)
          events << signal
          kill.call(signal, -group)
        end
        observe_reap = lambda do |pid, flags|
          events << :reap
          wait.call(pid, flags)
        end
        with_replaced_singleton_method(Process, :kill, selective_delivery) do
          with_replaced_singleton_method(Process, :waitpid2, observe_reap) do
            result = capture(FixtureArgv, env: env, timeout: 0.6)
            assert_equal [ "TERM", "KILL", :reap ], events.take(3)
            assert_equal({ "TERM" => :sent, "KILL" => :sent }, result.cleanup.signals)
            assert result.cleanup.stdout_eof
            assert result.cleanup.stderr_eof
            assert result.cleanup.reaped
            assert_equal :unconfirmed, result.cleanup.descendants
            assert_includes result.failure_message("codex", 0.6), "descendant termination unconfirmed"
            await_file(File.join(root, "judge.ready"))
            live = pipes.fetch("judge.live")
            assert_equal :wait_readable, live.read_nonblock(1, exception: false)
            # Exercise the same EOF cleanup used if any preceding assertion fails.
            pipes.fetch("stop_writer").close
            assert_exited(root, pipes, "judge")
          end
        end
      end
    end
  end

  def test_escaped_output_holder_cannot_block_settlement
    with_fixture("escaped") do |root, env, pipes|
      started = now
      result = capture(FixtureArgv, env: env, timeout: 0.6)
      assert result.timed_out
      assert_operator now - started, :<, 1.8
      refute result.cleanup.stdout_eof
      refute result.cleanup.stderr_eof
      assert result.cleanup.reaped
      assert_includes result.cleanup.limitations, "judge output pipes still open"
      pipes.fetch("stop_writer").close
      assert_exited(root, pipes, "child")
    end
  end

  def test_release_failure_never_reacquires_group_after_reaping_begins
    with_fixture("blocked") do |root, env, _|
      body = <<~'CODE'
        events.puts("ready #{Process.pid}")
        exit!(1) unless control.gets == "start\n"
        events.puts("exit 0")
        exit!(7) if control.gets == "release\n"
      CODE
      with_worker(root, body) do
        with_replaced_singleton_method(Process, :kill, ->(*) { raise "signal after release" }) do
          result = capture(FixtureArgv, env: env)
          assert result.status.success?
          assert result.cleanup.reaped
          assert_match(/custody release failed/, result.failure_message("claude", 3))
        end
      end
    end
  end

  def test_interrupt_cleans_the_group_before_propagating
    with_fixture("family") do |root, env, pipes|
      job = Thread.new do
        capture(FixtureArgv, env: env, timeout: 0)
      rescue Interrupt
        :interrupted
      end
      await_file(File.join(root, "child.ready"))
      job.raise(Interrupt)
      assert_equal :interrupted, job.value
      assert_exited(root, pipes, "child")
      assert_exited(root, pipes, "judge")
    ensure
      job&.kill&.join
    end
  end
end
