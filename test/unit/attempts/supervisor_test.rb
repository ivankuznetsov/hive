require "test_helper"
require "timeout"
require "hive/attempts/supervisor"

class AttemptsSupervisorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  def test_claims_before_worker_and_writes_failed_receipt_with_ordered_output
    worker_argv = [ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      ready_r, ready_w = IO.pipe
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        ready_io: ready_w, heartbeat_sec: 0.01, stale_sec: 1,
        first_heartbeat_timeout_sec: 1
      )

      exit_status = supervisor.run
      ready_w.close unless ready_w.closed?
      readiness = JSON.parse(ready_r.read)
      terminal = store.fetch(attempt.attempt_id)

      assert_equal true, readiness["claimed"]
      assert_equal 7, exit_status
      assert_equal "terminal", terminal.state
      assert_equal "failed", terminal.outcome
      assert_equal 7, terminal.receipt.fetch("exit_status")
      frames = Hive::Attempts::StreamLog.read(File.join(store.root, terminal.receipt.dig("log_reference", "path")))
      assert_equal %w[err out], frames.map(&:bytes).sort
      assert terminal["worker"].fetch("pid").positive?
    ensure
      ready_r&.close unless ready_r&.closed?
    end
  end

  def test_timeout_is_terminal_cancelled_and_kills_worker_group
    worker_argv = [ "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      heartbeat_count = 0
      heartbeat = store.method(:heartbeat)
      store.define_singleton_method(:heartbeat) do |*args, **kwargs|
        heartbeat_count += 1
        heartbeat.call(*args, **kwargs)
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.2, kill_grace_sec: 0.15
      )
      term_heartbeat_count = nil
      signal_worker_group = supervisor.method(:signal_worker_group)
      supervisor.define_singleton_method(:signal_worker_group) do |signal|
        term_heartbeat_count = heartbeat_count if signal == "TERM"
        signal_worker_group.call(signal)
      end

      assert_equal 124, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      assert_equal 124, terminal.receipt.fetch("exit_status")
      refute_nil term_heartbeat_count
      assert_operator heartbeat_count, :>, term_heartbeat_count,
                      "heartbeat must continue throughout TERM-to-KILL grace"
    end
  end

  def test_clean_leader_exit_terminates_a_lingering_descendant_group
    worker_argv = [ "/bin/sh", "-c", "(sleep 10) & exit 0" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        kill_grace_sec: 0.2
      )

      assert_equal 0, Timeout.timeout(2) { supervisor.run }
      assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
    end
  end

  def test_hive_worker_receives_capability_context_only_after_durable_checkpoint
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      worker = <<~'RUBY'
        context = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_CONTEXT_FD")), "r")
        gate = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_GATE_FD")), "r")
        abort "invalid capability" unless context.read == "c" * 64
        abort "gate not released" unless gate.read(1) == "1"
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 0, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      assert terminal.worker.fetch("pid").positive?
    end
  end

  def test_timeout_and_heartbeat_continue_while_descendant_holds_output_pipe
    worker_argv = [
      "/bin/sh", "-c",
      "(trap '' TERM; exec sleep 10) & printf 'leader-exited\\n'; exit 0"
    ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      heartbeat_count = 0
      heartbeat = store.method(:heartbeat)
      store.define_singleton_method(:heartbeat) do |*args, **kwargs|
        heartbeat_count += 1
        heartbeat.call(*args, **kwargs)
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.05, kill_grace_sec: 0.1
      )

      assert_equal 124, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      assert_operator heartbeat_count, :>, 0
      frames = Hive::Attempts::StreamLog.read(
        File.join(store.root, terminal.receipt.dig("log_reference", "path"))
      )
      assert_includes frames.map(&:bytes).join, "leader-exited"
    end
  end

  def test_lost_claim_exits_without_starting_worker
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      store.mark_lost(attempt, reason: "launch_timeout", now: NOW + 2)
      sentinel = File.join(store.root, "worker-started")
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        first_heartbeat_timeout_sec: 1
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      refute File.exist?(sentinel)
      assert_equal "lost", store.fetch(attempt.attempt_id).state
    end
  end

  def test_compare_and_swap_failure_reports_temporary_failure
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      ready = StringIO.new
      store.define_singleton_method(:claim) { |*_args, **_kwargs| raise Hive::Attempts::CompareAndSwapFailed, "lost" }
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), ready_io: ready
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      assert_includes ready.string, "lost"
    end
  end

  def test_invalid_capability_cannot_claim_or_start_the_recorded_worker
    with_tmp_dir do |root|
      sentinel = File.join(root, "worker-started")
      with_attempt(worker_argv: [ "/bin/sh", "-c", "touch #{sentinel}" ]) do |store, attempt|
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new("f" * 64)
        )

        assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
        refute File.exist?(sentinel)
        refute store.fetch(attempt.attempt_id).claimed?
      end
    end
  end

  def test_unexpected_running_failure_writes_a_failed_receipt
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      ready = StringIO.new
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), ready_io: ready
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "terminal", terminal.state
      assert_equal "failed", terminal.outcome
      assert_includes ready.string, '"claimed":true'
    end
  end

  def test_secondary_failure_during_unexpected_error_is_contained
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      original_fetch = store.method(:fetch)
      fetches = 0
      store.define_singleton_method(:fetch) do |attempt_id|
        fetches += 1
        raise "store unavailable" if fetches > 1

        original_fetch.call(attempt_id)
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
    end
  end

  def test_private_process_and_stream_helpers_cover_race_paths
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt", claim_io: StringIO.new(CLAIM_CAPABILITY),
      kill_grace_sec: 0, monotonic: -> { 1.0 }
    )

    wait_io = Struct.new(:closed?) do
      def read_nonblock(*_args, **_kwargs) = :wait_readable
      def close = nil
    end.new(false)
    readers = { wait_io => :stdout }
    supervisor.send(:drain_reader, wait_io, readers, Object.new)
    assert_equal({ wait_io => :stdout }, readers)

    broken_io = Struct.new(:closed?) do
      def read_nonblock(*_args, **_kwargs) = raise(IOError)
      def close = nil
    end.new(false)
    readers = { broken_io => :stderr }
    supervisor.send(:drain_reader, broken_io, readers, Object.new)
    assert_empty readers

    status = Struct.new(:exited?, :termsig).new(false, 9)
    assert_equal 137, supervisor.send(:status_exit, status)
    assert_equal Hive::ExitCodes::SOFTWARE, supervisor.send(:status_exit, nil)
    record = { "worker_argv" => [ "hive", "run", "task" ] }
    assert_equal RbConfig.ruby, supervisor.send(:resolved_worker_argv, record).first

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { raise Errno::ESRCH }) do
      assert_raises(Hive::Attempts::StoreError) { supervisor.send(:process_identity, 99) }
    end
  end

  def test_worker_termination_escalation_and_signal_setup_are_defensive
    ticks = [ 0.0, 0.0, 0.0, 0.01 ]
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt", claim_io: StringIO.new(CLAIM_CAPABILITY),
      kill_grace_sec: 0.01, monotonic: -> { ticks.shift || 0.01 }
    )
    supervisor.instance_variable_set(:@worker_pid, 456)
    signals = []
    sleeps = []
    supervisor.define_singleton_method(:signal_worker_group) { |signal| signals << signal }
    supervisor.define_singleton_method(:sleep) { |seconds| sleeps << seconds }
    status = Struct.new(:last).new(:killed)
    waits = [ nil, nil, status ]
    with_replaced_singleton_method(Process, :wait2, ->(*_args) { waits.shift }) do
      assert_equal :killed, supervisor.send(:terminate_worker_group)
    end
    assert_equal %w[TERM KILL], signals
    refute_empty sleeps

    with_replaced_singleton_method(Process, :wait2, ->(*_args) { raise Errno::ECHILD }) do
      assert_nil supervisor.send(:terminate_worker_group)
    end

    trapped = []
    with_replaced_singleton_method(Signal, :trap, ->(signal, &_block) { trapped << signal }) do
      supervisor.send(:install_signal_handlers!)
    end
    assert_equal %w[TERM INT], trapped

    ready = Object.new
    ready.define_singleton_method(:closed?) { false }
    ready.define_singleton_method(:write) { |_bytes| raise Errno::EPIPE }
    supervisor.instance_variable_set(:@ready_io, ready)
    supervisor.send(:signal_ready, "claimed" => true)
    assert_equal true, supervisor.instance_variable_get(:@ready_sent)

    supervisor.singleton_class.send(:remove_method, :signal_worker_group)
    supervisor.instance_variable_set(:@worker_pgid, 456)
    with_replaced_singleton_method(Process, :getpgid, ->(_pid) { 999 }) do
      assert_raises(Hive::Attempts::StoreError) { supervisor.send(:signal_worker_group, "TERM") }
    end
    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      refute supervisor.send(:signal_recorded_worker_group, "TERM")
    end
    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_raises(Hive::Attempts::StoreError) do
        supervisor.send(:signal_recorded_worker_group, "TERM")
      end
      assert supervisor.send(:recorded_worker_group_alive?)
    end

    unreadable = Object.new
    unreadable.define_singleton_method(:read) { |_limit| raise IOError }
    supervisor.instance_variable_set(:@claim_io, unreadable)
    assert_nil supervisor.send(:read_claim_capability)
  end

  private

  def with_attempt(worker_argv:)
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      attempt = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "durable-task",
        intended_stage: "4-execute", task_generation: "generation-1",
        progress_token: "progress-1", provider: "codex", worker_argv: worker_argv,
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY), starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
      )
      yield store, attempt
    end
  end
end
