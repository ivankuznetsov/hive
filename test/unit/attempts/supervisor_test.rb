require "test_helper"
require "timeout"
require "hive/attempts/diagnostic_channel"
require "hive/attempts/supervisor"
require "hive/patrol_fix/attempt_diagnostic"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/task_resolver"
require_relative "../../support/stream_log_test_support"

class AttemptsSupervisorTest < Minitest::Test
  include HiveTestHelper
  include StreamLogTestSupport

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  class SeparatorFaultWriter < StreamLogTestSupport::DelegatingIO
    attr_reader :separator_attempts

    def initialize(io, persistent:)
      super(io)
      @persistent = persistent
      @separator_attempts = 0
    end

    def syswrite(bytes)
      if bytes == "#\n".b
        @separator_attempts += 1
        raise Errno::EINTR, "separator" if @persistent || @separator_attempts == 1
      end

      @io.syswrite(bytes)
    end
  end

  class OneShotSyncFaultWriter < StreamLogTestSupport::DelegatingIO
    def initialize(io, operation:, error:)
      super(io)
      @operation = operation
      @error = error
      @raised = false
    end

    def flush
      raise_once(:flush)
      super
    end

    def fsync
      raise_once(:fsync)
      super
    end

    private

    def raise_once(operation)
      return unless @operation == operation && !@raised

      @raised = true
      raise @error
    end
  end

  def test_wrapper_registration_is_released_and_cleanup_errors_are_bounded
    calls = []
    registry = Object.new
    registry.define_singleton_method(:register!) { |*args, **kwargs| calls << [ args, kwargs ] }
    registry.define_singleton_method(:mark_stopped_by_reservation!) do |_id, **|
      raise Hive::RuntimeControlPlane::Unavailable.new("offline", code: :offline)
    end
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new,
      process_registry: registry, reservation_id: "reservation-1"
    )

    supervisor.send(:register_wrapper!)
    assert supervisor.instance_variable_get(:@wrapper_registered)
    assert_equal "reservation-1", calls.first.first.first
    assert_nil supervisor.send(:release_wrapper_registration)
  end

  def test_completion_storage_failure_leaves_running_attempt_without_a_receipt
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      store.pending_bookkeeping.define_singleton_method(:prepare_completion) do |*, **|
        raise Hive::Attempts::PendingBookkeeping::StorageError, "disk full"
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      _out, err = capture_io { assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run }
      assert_includes err, "completion remains uncommitted"
      assert_equal "running", store.fetch(attempt.attempt_id).state
      assert_nil store.fetch(attempt.attempt_id).receipt
    end
  end

  def test_pending_storage_failure_after_busy_exhaustion_still_returns_tempfail
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      mono = 0.0
      store.define_singleton_method(:claim) do |*, timeout_sec:, **|
        mono += timeout_sec
        raise SQLite3::BusyException, "busy"
      end
      store.pending_bookkeeping.define_singleton_method(:record_busy) do |*, **|
        raise Hive::Attempts::PendingBookkeeping::StorageError, "disk full"
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY),
        bookkeeping_timeout_sec: 0.1, monotonic: -> { mono }, sleeper: ->(seconds) { mono += seconds }
      )
      _out, err = capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run }
      assert_includes err, "pending bookkeeping storage failed: disk full"
      assert_equal "launching", store.fetch(attempt.attempt_id).state
    end
  end

  def test_failed_worker_completion_is_preserved_when_error_terminalization_is_busy
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      mono = 0.0
      store.define_singleton_method(:terminalize) do |*, timeout_sec:, **|
        mono += timeout_sec
        raise SQLite3::BusyException, "busy"
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY),
        busy_tolerance_sec: 0.1, monotonic: -> { mono }, sleeper: ->(seconds) { mono += seconds }
      )
      supervisor.define_singleton_method(:run_worker) { |*| raise IOError, "worker setup failed" }
      capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run }
      current = store.fetch(attempt.attempt_id)
      assert_equal "running", current.state
      pending = store.pending_bookkeeping.read(current)
      assert_equal :valid, pending.status
      assert_equal "failed", pending.document.fetch("terminal_receipt").fetch("outcome")
    end
  end

  def test_cancellation_observed_after_worker_exit_preserves_success
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      supervisor.instance_variable_set(:@cancel_reason, :timeout)
      wait = Process.method(:wait2)
      # Resolve the worker exit at the cancellation check to exercise that race
      # without depending on scheduler timing.
      with_replaced_singleton_method(Process, :wait2, ->(pid, _flags) { wait.call(pid) }) do
        assert_equal 0, supervisor.run
      end
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      refute_nil terminal.worker
      assert_nil supervisor.instance_variable_get(:@cancel_reason)
    end
  end

  def test_cancellation_before_registration_persists_worker_identity
    with_attempt(worker_argv: [ "/bin/sleep", "30" ]) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY),
        kill_grace_sec: 0.05
      )
      supervisor.instance_variable_set(:@cancel_reason, :signal)
      supervisor.instance_variable_set(:@cancel_signal, "TERM")

      assert_equal 143, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      refute_nil terminal.worker
      assert_equal :missing, Hive::Attempts::ProcessIdentity.new.status(terminal.worker)
    end
  end

  def test_timeout_before_registration_persists_worker_identity
    with_attempt(worker_argv: [ "/bin/sleep", "30" ]) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY),
        timeout_sec: Float::MIN, kill_grace_sec: 0.05
      )

      assert_equal 124, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      refute_nil terminal.worker
      assert_equal :missing, Hive::Attempts::ProcessIdentity.new.status(terminal.worker)
    end
  end

  def test_quiescence_before_registration_persists_worker_custody_before_interruption
    with_attempt(worker_argv: [ "/bin/sleep", "30" ]) do |store, attempt|
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: store.database)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY),
        kill_grace_sec: 0.05
      )
      identity = supervisor.method(:process_identity)
      supervisor.define_singleton_method(:process_identity) do |pid|
        captured = identity.call(pid)
        unless pid == Process.pid
          lifecycle.begin_quiesce!(
            deadline_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
            boot_id: "test-boot", shutdown_grace_sec: 0.05
          )
          @cancel_reason = :signal
          @cancel_signal = "TERM"
        end
        captured
      end

      assert_equal 143, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "interrupted", terminal.outcome
      refute_nil terminal.worker
      assert_equal :missing, Hive::Attempts::ProcessIdentity.new.status(terminal.worker)
      assert_equal lifecycle.current.generation, terminal.receipt.fetch("pause_generation")
      cleanup_writes = store.database.read do |db|
        db[:quiescence_cleanup_writes].select_map(:attempt_id)
      end
      assert_equal [ attempt.attempt_id, "worker:#{attempt.attempt_id}" ].sort, cleanup_writes.sort
    end
  end

  def test_cancelled_hive_worker_registration_does_not_release_execution_gate
    with_attempt(worker_argv: [ "hive", "run", "durable-task" ]) do |store, attempt|
      invoked = File.join(store.root, "unexpected-execution")
      worker = <<~'RUBY'
        gate = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_GATE_FD")), "r")
        File.write(ARGV.fetch(0), "executed") if gate.read(1) == "1"
        sleep 30
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY),
        kill_grace_sec: 0.3
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker, invoked ]
      end
      signal = supervisor.method(:signal_worker_group)
      supervisor.define_singleton_method(:signal_worker_group) do |name|
        name == "TERM" ? true : signal.call(name)
      end
      supervisor.instance_variable_set(:@cancel_reason, :signal)
      supervisor.instance_variable_set(:@cancel_signal, "TERM")

      assert_equal 143, Timeout.timeout(3) { supervisor.run }
      refute_nil store.fetch(attempt.attempt_id).worker
      refute File.exist?(invoked)
    end
  end

  def test_short_worker_registration_retries_before_publishing_terminal_receipt
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      calls = fail_store_calls(store, :checkpoint, times: 1)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY)
      )

      assert_equal 0, Timeout.timeout(3) { supervisor.run }
      assert_equal 2, calls.call
      refute_nil store.fetch(attempt.attempt_id).worker
    end
  end

  def test_ambiguous_worker_registration_adopts_the_exact_committed_winner
    with_tmp_dir do |root|
      release = File.join(root, "registration-observed")
      worker = [ RbConfig.ruby, "-e", "sleep 0.01 until File.exist?(ARGV.fetch(0))", release ]
      with_attempt(worker_argv: worker) do |store, attempt|
        checkpoint = store.method(:checkpoint)
        fetch = store.method(:fetch)
        calls = 0
        store.define_singleton_method(:checkpoint) do |*args, **options|
          calls += 1
          result = checkpoint.call(*args, **options)
          raise SQLite3::BusyException, "ambiguous commit" if calls == 1
          result
        end
        store.define_singleton_method(:fetch) do |*args, **options|
          record = fetch.call(*args, **options)
          File.write(release, "1") if record&.worker
          record
        end
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY)
        )
        assert_equal 0, Timeout.timeout(10) { supervisor.run }
        assert_equal 1, calls
        assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
        refute_nil supervisor.last_durable_record.worker
      end
    end
  end

  def test_short_worker_registration_result_cannot_adopt_a_different_lease
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      checkpoint = store.method(:checkpoint)
      wait = Process.method(:wait2)
      exited = nil
      store.define_singleton_method(:checkpoint) do |*args, **options|
        registered = checkpoint.call(*args, **options)
        heartbeat(registered, stale_sec: 30, now: Time.now.utc)
        exited = wait.call(registered.worker.fetch("pid"))
        raise SQLite3::BusyException, "ambiguous commit"
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id, claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      replacement = lambda do |pid, flags|
        if exited && exited.first == pid
          result, exited = exited, nil
          result
        else
          wait.call(pid, flags)
        end
      end
      _out, err = capture_io do
        with_replaced_singleton_method(Process, :wait2, replacement) do
          assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
        end
      end
      assert_includes err, "worker registration result changed ownership"
      assert_equal "running", store.fetch(attempt.attempt_id).state
    end
  end

  def test_quiescence_lifecycle_probe_errors_fail_closed_without_crashing_worker
    lifecycle = Object.new
    lifecycle.define_singleton_method(:current) do
      raise Hive::RuntimeControlPlane::Unavailable.new("offline", code: :offline)
    end
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new
    )
    supervisor.define_singleton_method(:lifecycle) { lifecycle }

    refute supervisor.send(:admission_closed?)
    assert_nil supervisor.send(:capture_quiescence_context, 1.0)
  end

  def test_failed_initial_signal_is_retried_before_forcing_worker_exit
    with_attempt(worker_argv: [ "/bin/sh", "-c", "sleep 0.1; exit 0" ]) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      signals = 0
      original = supervisor.method(:signal_worker_group)
      supervisor.define_singleton_method(:signal_worker_group) do |signal|
        signals += 1
        signals == 1 ? false : original.call(signal)
      end
      supervisor.instance_variable_set(:@cancel_reason, :timeout)

      assert_equal 124, supervisor.run
      assert_operator signals, :>=, 2
    end
  end

  def test_quiescing_handshake_denial_exits_before_worker_and_leaves_reservation_for_controller
    with_attempt(worker_argv: [ "/bin/sh", "-c", "touch should-not-run" ]) do |store, attempt|
      releases = []
      registry = Object.new
      registry.define_singleton_method(:register!) do |*, **|
        raise Hive::RuntimeControlPlane::AdmissionClosed.new(
          "admission closed", details: { generation: 2, phase: "quiescing" }
        )
      end
      registry.define_singleton_method(:mark_stopped_by_reservation!) { |id| releases << id }
      ready = StringIO.new
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), ready_io: ready,
        process_registry: registry, reservation_id: "reservation-1"
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      assert_equal "quiescing", JSON.parse(ready.string).fetch("state")
      assert_empty releases,
                   "the privileged controller, not the denied child, settles the reservation"
      assert_equal "launching", store.fetch(attempt.attempt_id).state
    end
  end

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

  BUSY = "attempt transition failed: SQLite3::BusyException: database is locked".freeze

  def fail_store_calls(store, name, times:, message: BUSY)
    calls = 0
    original = store.method(name)
    store.define_singleton_method(name) do |*args, **kwargs|
      calls += 1
      if calls <= times
        cause = message == BUSY ? SQLite3::BusyException.new("database is locked") : nil
        raise Hive::Attempts::RepositoryError, message, cause: cause
      end

      original.call(*args, **kwargs)
    end
    -> { calls }
  end

  def test_real_sql_lock_delays_claim_with_bounded_positive_tries_and_one_worker
    with_tmp_dir do |directory|
      invocations = File.join(directory, "invocations")
      with_attempt(worker_argv: [ "/bin/sh", "-c", "printf run >> #{invocations}" ]) do |store, attempt|
        measurements = []
        store.database.instance_variable_set(:@transaction_observer, ->(entry) { measurements << entry })
        with_sql_holder(store, seconds: 2.2) do
          supervisor = Hive::Attempts::Supervisor.new(
            store: store, attempt_id: attempt.attempt_id,
            claim_io: StringIO.new(CLAIM_CAPABILITY),
            heartbeat_sec: 0.02, stale_sec: 5, first_heartbeat_timeout_sec: 5
          )
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          assert_equal 0, supervisor.run
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          assert_operator elapsed, :>=, 2.0
          assert_operator elapsed, :<, 5.0
        end
        assert_equal "run", File.read(invocations)
        claims = measurements.select { |entry| entry[:operation] == "attempt.claim" }
        assert_operator claims.length, :>=, 3
        blocked = claims.reject { |entry| entry[:result] == "committed" }
        assert blocked.all? { |entry| entry[:sqlite_wait_sec] > 0.0 && entry[:sqlite_wait_sec] < 1.1 }, blocked.inspect
        assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
      end
    end
  end

  def test_contended_claim_exhausts_strictly_before_lifecycle_expiry_without_work
    with_tmp_dir do |directory|
      invocations = File.join(directory, "invocations")
      with_attempt(worker_argv: [ "/bin/sh", "-c", "touch #{invocations}" ]) do |store, attempt|
        store.arm_launch_handoff(attempt, launch_timeout_sec: 0.2, now: Time.now.utc)
        with_sql_holder(store, seconds: 0.5) do
          supervisor = Hive::Attempts::Supervisor.new(
            store: store, attempt_id: attempt.attempt_id,
            claim_io: StringIO.new(CLAIM_CAPABILITY)
          )
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          _, error = capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run }
          assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.35
          assert_includes error, "runtime_bookkeeping_busy"
          refute_includes error, "launch claim deadline expired"
        end
        refute File.exist?(invocations)
        assert_equal "launching", store.fetch(attempt.attempt_id).state
      end
    end
  end

  def test_ambiguous_claim_first_heartbeat_and_terminal_commit_fetch_the_winner
    %i[claim first_heartbeat checkpoint terminalize heartbeat].each do |operation|
      script = operation == :heartbeat ? [ "/bin/sleep", "0.2" ] : [ "/bin/true" ]
      with_attempt(worker_argv: script) do |store, attempt|
        original = store.method(operation)
        calls = 0
        store.define_singleton_method(operation) do |*arguments, **keywords|
          calls += 1
          result = original.call(*arguments, **keywords)
          raise SQLite3::BusyException, "ambiguous commit" if calls == 1

          result
        end
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new(CLAIM_CAPABILITY),
          heartbeat_sec: 0.02, stale_sec: 5, first_heartbeat_timeout_sec: 5
        )
        assert_equal 0, supervisor.run, operation.to_s
        terminal = store.fetch(attempt.attempt_id)
        assert_equal "succeeded", terminal.outcome
        if operation == :heartbeat
          assert_operator terminal.lease_version, :>, 4
          assert_operator calls, :>=, 1
        else
          assert_equal 4, terminal.lease_version
          assert_equal operation == :terminalize ? 2 : 1, calls
        end
      end
    end
  end

  def test_worker_registration_contention_keeps_timeout_and_output_drain_responsive
    with_attempt(worker_argv: [ "/bin/sh", "-c", "printf started; sleep 30" ]) do |store, attempt|
      fail_store_calls(store, :checkpoint, times: Float::INFINITY)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), timeout_sec: 0.1,
        heartbeat_sec: 0.02, stale_sec: 5, first_heartbeat_timeout_sec: 5,
        kill_grace_sec: 0.05, busy_tolerance_sec: 0.1
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, Timeout.timeout(2) { supervisor.run } }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "running", terminal.state
      assert_nil terminal.receipt
      assert_equal :missing, Hive::Attempts::ProcessIdentity.new.status(
        "pid" => supervisor.instance_variable_get(:@worker_pid)
      )
      assert_equal :valid, store.pending_bookkeeping.read(terminal).status
      frames = Hive::Attempts::StreamLog.read(store.log_archive.hot_path(attempt.attempt_id))
      assert frames.any? { |frame| frame.bytes.include?("started") }
    end
  end

  def test_busy_heartbeats_are_deferred_while_the_lease_is_unexpired
    with_attempt(worker_argv: [ "/bin/sh", "-c", "sleep 0.7; exit 0" ]) do |store, attempt|
      heartbeats = fail_store_calls(store, :heartbeat, times: 3)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 5, first_heartbeat_timeout_sec: 5
      )

      assert_equal 0, supervisor.run
      assert_operator heartbeats.call, :>, 3, "heartbeats resume after the busy ones"
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      frames = Hive::Attempts::StreamLog.read(File.join(store.root, terminal.receipt.dig("log_reference", "path")))
      assert frames.any? { |frame| frame.bytes.include?("heartbeat deferred") }
    end
  end

  def test_heartbeats_busy_past_the_busy_tolerance_end_the_attempt
    with_attempt(worker_argv: [ "/bin/sh", "-c", "sleep 30" ]) do |store, attempt|
      fail_store_calls(store, :heartbeat, times: Float::INFINITY)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 0.3, first_heartbeat_timeout_sec: 5,
        busy_tolerance_sec: 0.3
      )

      _, err = capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, Timeout.timeout(10) { supervisor.run } }
      assert_includes err, "runtime_bookkeeping_busy: heartbeat exhausted"
      assert_equal store.fetch(attempt.attempt_id).to_h, supervisor.last_durable_record.to_h
      assert_equal "running", supervisor.last_durable_record.state
    end
  end

  def test_non_busy_heartbeat_failures_end_the_attempt_immediately
    with_attempt(worker_argv: [ "/bin/sh", "-c", "sleep 30" ]) do |store, attempt|
      heartbeats = fail_store_calls(store, :heartbeat, times: 1, message: "attempt transition failed: disk I/O error")
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 5, first_heartbeat_timeout_sec: 5
      )

      capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, Timeout.timeout(10) { supervisor.run } }
      assert_equal 1, heartbeats.call
    end
  end

  def test_busy_terminal_receipt_is_retried
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 3" ]) do |store, attempt|
      terminalizations = fail_store_calls(store, :terminalize, times: 2)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 5, first_heartbeat_timeout_sec: 5
      )
      supervisor.define_singleton_method(:sleep) { |seconds| Kernel.sleep([ seconds, 0.01 ].min) }

      assert_equal 3, supervisor.run
      assert_equal 3, terminalizations.call
      assert_equal "terminal", store.fetch(attempt.attempt_id).state
    end
  end

  def test_busy_retries_stop_at_the_busy_tolerance
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 0" ]) do |store, attempt|
      fail_store_calls(store, :terminalize, times: Float::INFINITY)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 0.2, first_heartbeat_timeout_sec: 5,
        busy_tolerance_sec: 0.2
      )
      supervisor.define_singleton_method(:sleep) { |seconds| Kernel.sleep([ seconds, 0.01 ].min) }

      capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, Timeout.timeout(10) { supervisor.run } }
    end
  end

  def test_busy_claim_and_first_heartbeat_are_retried
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 0" ]) do |store, attempt|
      claims = fail_store_calls(store, :claim, times: 2)
      first_heartbeats = fail_store_calls(store, :first_heartbeat, times: 2)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 5, first_heartbeat_timeout_sec: 5
      )
      supervisor.define_singleton_method(:sleep) { |seconds| Kernel.sleep([ seconds, 0.01 ].min) }

      assert_equal 0, supervisor.run
      assert_equal [ 3, 3 ], [ claims.call, first_heartbeats.call ]
      assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
    end
  end

  # Busy retries never outlive the first-heartbeat deadline: the retry budget
  # is capped inside it and the repository re-checks it, so the attempt fails closed.
  def test_busy_first_heartbeat_fails_closed_at_its_deadline
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 0" ]) do |store, attempt|
      store.define_singleton_method(:first_heartbeat) do |observed, **kwargs|
        raise Hive::Attempts::CompareAndSwapFailed, "first heartbeat deadline expired" if
          observed.active_deadline && kwargs.fetch(:now) > observed.active_deadline
        raise Hive::Attempts::RepositoryError, AttemptsSupervisorTest::BUSY,
              cause: SQLite3::BusyException.new("database is locked")
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 5, first_heartbeat_timeout_sec: 0.2
      )
      supervisor.define_singleton_method(:sleep) { |seconds| Kernel.sleep([ seconds, 0.01 ].min) }

      _, err = capture_io do
        assert_equal Hive::ExitCodes::TEMPFAIL, Timeout.timeout(10) { supervisor.run }
      end
      # The bounded retry is capped inside the persisted first-heartbeat
      # deadline, so it exhausts as typed bookkeeping busy before expiry.
      assert_includes err, "runtime_bookkeeping_busy: first_heartbeat exhausted"
      assert_equal "launching", store.fetch(attempt.attempt_id).state
    end
  end

  # A swapping host can hold the write lock past the lease window; a live
  # owner is only a reconciler suspect then, so busy heartbeats keep deferring.
  def test_busy_heartbeats_outlast_the_lease_window
    with_attempt(worker_argv: [ "/bin/sh", "-c", "sleep 0.6; exit 0" ]) do |store, attempt|
      fail_store_calls(store, :heartbeat, times: 40)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 0.1, first_heartbeat_timeout_sec: 5,
        busy_tolerance_sec: 5
      )

      assert_equal 0, supervisor.run
      assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
    end
  end

  def test_lost_compare_and_swap_is_never_retried
    { heartbeat: "sleep 30", terminalize: "exit 0" }.each do |name, script|
      with_attempt(worker_argv: [ "/bin/sh", "-c", script ]) do |store, attempt|
        calls = 0
        store.define_singleton_method(name) do |*|
          calls += 1
          raise Hive::Attempts::CompareAndSwapFailed, "attempt lease compare-and-swap lost"
        end
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new(CLAIM_CAPABILITY),
          heartbeat_sec: 0.01, stale_sec: 5, first_heartbeat_timeout_sec: 5
        )

        capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, Timeout.timeout(10) { supervisor.run } }
        assert_equal 1, calls, "#{name} must not retry a lost lease"
      end
    end
  end

  def test_quiesce_signal_is_terminal_interrupted_only_after_worker_stops
    worker_argv = [ "/bin/sh", "-c", "trap '' TERM; printf partial; while :; do sleep 1; done" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: store.database)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 60
      )
      checkpoint = store.method(:checkpoint)
      store.define_singleton_method(:checkpoint) do |*args, **kwargs|
        recorded = checkpoint.call(*args, **kwargs)
        lifecycle.begin_quiesce!(
          deadline_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
          boot_id: "test-boot", shutdown_grace_sec: 0.05
        )
        supervisor.instance_variable_set(:@cancel_reason, :signal)
        supervisor.instance_variable_set(:@cancel_signal, "TERM")
        recorded
      end

      assert_equal 143, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)

      assert_equal "terminal", terminal.state
      assert_equal "interrupted", terminal.outcome
      assert_equal lifecycle.current.generation, terminal.receipt.fetch("pause_generation")
      assert_equal terminal.checkpoint, terminal.receipt.fetch("final_checkpoint")
      assert File.file?(File.join(store.root, terminal.receipt.dig("log_reference", "path")))
      assert_equal :missing, Hive::Attempts::ProcessIdentity.new.status(terminal.worker)
      assert_equal 1, store.database.read { |db| db[:quiescence_cleanup_writes].count }
    end
  end

  def test_quiesce_signal_never_consumes_the_finalization_reserve
    state = Hive::RuntimeControlPlane::Lifecycle.new(
      phase: "quiescing", generation: 4, revision: 1, mutation_sequence: 2,
      boot_id: "boot", deadline_monotonic: 110.0, shutdown_grace_sec: 25.0,
      interrupted_attempt_ids: [], quiesce_started_at: nil, paused_at: nil,
      resumed_at: nil, updated_at: nil
    )
    lifecycle = Object.new
    lifecycle.define_singleton_method(:current) { state }
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new,
      kill_grace_sec: 60, monotonic: -> { 95.0 }
    )
    supervisor.define_singleton_method(:lifecycle) { lifecycle }

    supervisor.send(:capture_quiescence_context, 95.0)

    assert_equal 4, supervisor.instance_variable_get(:@pause_generation)
    assert_equal 0.0, supervisor.send(:effective_kill_grace)
  end

  def test_natural_completion_after_admission_closes_keeps_genuine_success
    with_attempt(worker_argv: [ "/bin/sh", "-c", "sleep 0.1; exit 0" ]) do |store, attempt|
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: store.database)
      checkpoint = store.method(:checkpoint)
      store.define_singleton_method(:checkpoint) do |*args, **kwargs|
        recorded = checkpoint.call(*args, **kwargs)
        lifecycle.begin_quiesce!(
          deadline_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
          boot_id: "test-boot", shutdown_grace_sec: 0.05
        )
        recorded
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1
      )

      assert_equal 0, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)

      assert_equal "terminal", terminal.state
      assert_equal "succeeded", terminal.outcome
      assert_nil terminal.receipt.fetch("pause_generation")
      assert_equal 1, store.database.read { |db| db[:quiescence_cleanup_writes].count }
    end
  end

  def test_worker_completed_before_quiesce_signal_keeps_genuine_success
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 0" ]) do |store, attempt|
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: store.database)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 0.05
      )
      checkpoint = store.method(:checkpoint)
      store.define_singleton_method(:checkpoint) do |*args, **kwargs|
        recorded = checkpoint.call(*args, **kwargs)
        sleep 0.05
        lifecycle.begin_quiesce!(
          deadline_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
          boot_id: "test-boot", shutdown_grace_sec: 0.05
        )
        supervisor.instance_variable_set(:@cancel_reason, :signal)
        supervisor.instance_variable_set(:@cancel_signal, "TERM")
        recorded
      end

      assert_equal 0, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)

      assert_equal "succeeded", terminal.outcome
      assert_nil terminal.receipt.fetch("pause_generation")
    end
  end

  def test_supervisor_does_not_busy_spin_after_output_pipes_close
    worker_argv = [ "/bin/sh", "-c", "exec 1>&- 2>&-; sleep 1" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 5, stale_sec: 30, first_heartbeat_timeout_sec: 30
      )
      sleep_calls = []
      supervisor.define_singleton_method(:sleep) do |duration|
        sleep_calls << duration
        Kernel.sleep(duration)
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cpu_started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      assert_equal 0, Timeout.timeout(10) { supervisor.run }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      cpu_used = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu_started

      assert_operator elapsed, :>=, 1.0, "supervisor must await worker exit"
      assert(sleep_calls.any?(&:positive?),
             "supervisor must sleep while all output pipes are at EOF")
      assert_operator cpu_used / elapsed, :<, 0.5,
                      "supervisor must not spin at full CPU while pipes are at EOF"
      assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
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

  def test_explicit_worker_safe_evidence_pipe_binds_signal_to_failed_terminal_receipt
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(worker_argv: worker_argv, routing: explicit_routing) do |store, attempt|
      signal = {
        "failure_class" => "model_capacity",
        "scope" => {
          "kind" => "model", "provider_account_id" => "account-a", "model" => "model-a"
        },
        "provenance" => "codex_jsonl_transport",
        "reset_hint_seconds" => 30
      }
      worker = <<~RUBY
        gate = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_GATE_FD")), "r")
        abort "gate not released" unless gate.read(1) == "1"
        evidence = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_EVIDENCE_FD")), "w")
        evidence.write(#{JSON.generate("#{JSON.generate(signal)}\n")})
        evidence.close
        puts "raw-provider-message=secret-canary"
        exit 0
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal Hive::ExitCodes::SOFTWARE, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "failed", terminal.outcome
      assert_equal "model_capacity", terminal.receipt.dig("provider_evidence", "failure_class")
      assert_equal terminal.receipt.fetch("log_reference"),
                   terminal.receipt.dig("provider_evidence", "source_reference")
      refute_includes JSON.generate(terminal.receipt), "secret-canary"
    end
  end

  def test_provider_signal_owns_missing_frame_patrol_diagnostic
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, routing: explicit_routing,
      intended_stage: "2-fix", workflow_controller: :patrol_fix
    ) do |store, attempt|
      signal = {
        "failure_class" => "model_capacity",
        "scope" => {
          "kind" => "model", "provider_account_id" => "account-a", "model" => "model-a"
        },
        "provenance" => "codex_jsonl_transport",
        "reset_hint_seconds" => 30
      }
      worker = <<~RUBY
        evidence = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_EVIDENCE_FD")), "w")
        evidence.write(#{JSON.generate("#{JSON.generate(signal)}\n")})
        evidence.close
        exit 0
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal Hive::ExitCodes::SOFTWARE, Timeout.timeout(10) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "model_capacity", diagnostic.fetch("code")
      assert_equal "provider", diagnostic.fetch("owner")
      assert_equal "codex", diagnostic.dig("provider", "name")
      assert_equal "model_capacity", diagnostic.dig("provider", "failure_class")
      assert_equal "codex_jsonl_transport", diagnostic.dig("provider", "provenance")
      assert_equal "30", diagnostic.dig("provider", "retry_hint")
      assert_equal "missing", diagnostic.fetch("transport_status")
    end
  end

  def test_failed_bench_publish_does_not_receive_a_patrol_diagnostic
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "5-publish",
      workflow_controller: :benchmark
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "exit 7" ]
      end

      assert_equal 7, Timeout.timeout(2) { supervisor.run }
      assert_empty store.fetch(attempt.attempt_id).receipt.fetch("output_references")
    end
  end

  def test_failed_patrol_inbox_receives_a_bound_diagnostic
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "1-inbox",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "exit 8" ]
      end

      assert_equal 8, Timeout.timeout(2) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal "1-inbox", diagnostic.fetch("stage")
    end
  end

  def test_patrol_diagnostic_pipe_binds_one_artifact_and_exact_log_to_terminal_receipt
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
        {
          "status" => "error", "exit_code" => 7, "timed_out" => false,
          "cancelled" => false, "signal" => nil,
          "report_status" => "unknown", "firewall_status" => "clean",
          "custody_status" => "clean", "detail" => "agent exited without a report"
        },
        stage: "4-review",
        task_generation: attempt.task_generation,
        attempt_id: attempt.attempt_id,
        recorded_at: NOW
      )
      secret = "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
      draft = draft.merge("detail" => "\e[31magent failed #{secret}")
      worker = <<~RUBY
        diagnostic = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_DIAGNOSTIC_FD")), "w")
        diagnostic.write(#{JSON.generate("#{JSON.generate(draft)}\n")})
        diagnostic.close
        warn "private provider body"
        exit 7
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 7, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      references = terminal.receipt.fetch("output_references")
      assert_equal 1, references.length
      reference = references.fetch(0)
      assert Hive::OutputReference.verify(reference, root: store.root)
      diagnostic = JSON.parse(File.binread(File.join(store.root, reference.fetch("path"))))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal attempt.attempt_id, diagnostic.fetch("correlation_id")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
      assert_equal "malformed", diagnostic.fetch("transport_status")
      assert_nil diagnostic.fetch("detail")
      refute_includes JSON.generate(diagnostic), secret
      refute_includes JSON.generate(diagnostic), "\e[31m"
      refute_includes JSON.generate(diagnostic), "private provider body"
    end
  end

  def test_diagnostic_pipe_is_single_frame_bounded_and_fails_closed
    assert_operator Hive::Attempts::DiagnosticChannel::MAX_FRAME_BYTES, :<, 4_096

    missing = Hive::Attempts::DiagnosticChannel.read(StringIO.new(""))
    assert_nil missing.document
    assert_equal "missing", missing.status

    malformed = Hive::Attempts::DiagnosticChannel.read(StringIO.new("{\n"))
    assert_nil malformed.document
    assert_equal "malformed", malformed.status

    duplicate = Hive::Attempts::DiagnosticChannel.read(StringIO.new("{}\n{}\n"))
    assert_nil duplicate.document
    assert_equal "duplicate", duplicate.status

    oversized = Hive::Attempts::DiagnosticChannel.read(
      StringIO.new("x" * (Hive::Attempts::DiagnosticChannel::MAX_FRAME_BYTES + 1))
    )
    assert_nil oversized.document
    assert_equal "oversized", oversized.status
  end

  def test_diagnostic_channel_contains_writer_and_reader_io_failures
    writer = Hive::Attempts::DiagnosticChannel::Writer.new(StringIO.new)
    with_replaced_singleton_method(
      Hive::PatrolFix::AttemptDiagnostic, :validate!, ->(*, **) { true }
    ) do
      assert_raises(IOError) do
        writer.write("detail" => "x" * Hive::Attempts::DiagnosticChannel::MAX_FRAME_BYTES)
      end
    end

    broken_close = Object.new
    broken_close.define_singleton_method(:closed?) { false }
    broken_close.define_singleton_method(:close) { raise IOError }
    refute Hive::Attempts::DiagnosticChannel::Writer.new(broken_close).close

    unavailable = Object.new
    unavailable.define_singleton_method(:read) { |_limit| raise IOError }
    unavailable.define_singleton_method(:closed?) { false }
    unavailable.define_singleton_method(:close) { @closed = true }
    result = Hive::Attempts::DiagnosticChannel.read(unavailable)
    assert_equal "unavailable", result.status
    assert_nil result.document
  end

  def test_supervisor_finalizes_valid_frames_and_synthesizes_identity_mismatches
    with_attempt(
      worker_argv: [ "hive", "run", "durable-task" ], intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |_store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: Object.new, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), clock: -> { NOW }
      )
      log_reference = {
        "path" => "logs/attempt-1.frames", "size" => 12, "sha256" => "a" * 64
      }
      draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "exit_code" => 7 },
        stage: "4-review", task_generation: attempt.task_generation,
        attempt_id: attempt.attempt_id, recorded_at: NOW
      )
      frame = Hive::Attempts::DiagnosticChannel::ReadResult.new(
        document: draft, status: "valid"
      )

      finalized = supervisor.send(
        :finalize_or_synthesize_diagnostic, attempt, frame,
        log_reference: log_reference, exit_status: 7, outcome: "failed",
        transport_status: "valid"
      )
      assert_equal "valid", finalized.fetch("transport_status")
      assert_equal log_reference, finalized.fetch("log_reference")

      mismatched = frame.with(document: draft.merge(
        "attempt_id" => "other-attempt", "correlation_id" => "other-attempt"
      ))
      fallback = supervisor.send(
        :finalize_or_synthesize_diagnostic, attempt, mismatched,
        log_reference: log_reference, exit_status: 7, outcome: "failed",
        transport_status: "valid"
      )
      assert_equal "malformed", fallback.fetch("transport_status")
      assert_equal attempt.attempt_id, fallback.fetch("attempt_id")
    end
  end

  def test_existing_diagnostic_collision_is_read_with_a_strict_bound_and_no_symlinks
    with_tmp_dir do |root|
      path = File.join(root, Hive::PatrolFix::AttemptDiagnostic::FILENAME)
      supervisor = Hive::Attempts::Supervisor.new(
        store: Object.new, attempt_id: "attempt-1",
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      File.binwrite(
        path, "x" * (Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES + 1)
      )
      error = assert_raises(Hive::Attempts::RepositoryError) do
        supervisor.send(:persist_diagnostic_once, path, {})
      end
      assert_match(/size limit/, error.message)

      target = File.join(root, "target")
      File.binwrite(target, "{}")
      File.unlink(path)
      File.symlink(target, path)
      assert_raises(Hive::Attempts::RepositoryError) do
        supervisor.send(:persist_diagnostic_once, path, {})
      end
    end
  end

  def test_existing_diagnostic_reconciliation_accepts_exact_bytes_and_rejects_other_shapes
    with_tmp_dir do |root|
      supervisor = Hive::Attempts::Supervisor.new(
        store: Object.new, attempt_id: "attempt-1",
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      log_reference = {
        "path" => "logs/attempt-1.frames", "size" => 12, "sha256" => "a" * 64
      }
      document = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "exit_code" => 1 },
        stage: "4-review", task_generation: "generation-1",
        attempt_id: "attempt-1", recorded_at: NOW, log_reference: log_reference
      )
      path = File.join(root, Hive::PatrolFix::AttemptDiagnostic::FILENAME)

      assert supervisor.send(:persist_diagnostic_once, path, document)
      assert supervisor.send(:persist_diagnostic_once, path, document)
      conflict = document.merge("recorded_at" => (NOW + 1).iso8601(6))
      assert_raises(Hive::Attempts::RepositoryError) do
        supervisor.send(:persist_diagnostic_once, path, conflict)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        supervisor.send(:persist_diagnostic_once, File.join(root, "missing", "diagnostic"), document)
      end

      fake_status = Object.new
      fake_status.define_singleton_method(:file?) { false }
      fake_status.define_singleton_method(:nlink) { 1 }
      fake_status.define_singleton_method(:size) { 0 }
      fake_file = Object.new
      fake_file.define_singleton_method(:stat) { fake_status }
      with_replaced_singleton_method(File, :open, ->(*_args, &block) { block.call(fake_file) }) do
        assert_raises(Hive::Attempts::RepositoryError) do
          supervisor.send(:read_existing_diagnostic, path)
        end
      end

      fake_status.define_singleton_method(:file?) { true }
      fake_status.define_singleton_method(:size) do
        Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES
      end
      fake_file.define_singleton_method(:read) do |_limit|
        "x" * (Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES + 1)
      end
      with_replaced_singleton_method(File, :open, ->(*_args, &block) { block.call(fake_file) }) do
        error = assert_raises(Hive::Attempts::RepositoryError) do
          supervisor.send(:read_existing_diagnostic, path)
        end
        assert_match(/size limit/, error.message)
      end
    end
  end

  def test_failed_patrol_attempt_synthesizes_bound_diagnostic_when_frame_is_malformed
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      worker = <<~'RUBY'
        diagnostic = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_DIAGNOSTIC_FD")), "w")
        diagnostic.write("{malformed\n")
        diagnostic.close
        exit 9
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 9, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      references = terminal.receipt.fetch("output_references")
      assert_equal 1, references.length
      diagnostic = JSON.parse(File.binread(File.join(store.root, references.fetch(0).fetch("path"))))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal "malformed", diagnostic.fetch("transport_status")
      assert_equal attempt.task_generation, diagnostic.fetch("task_generation")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_secret_bearing_metadata_frame_is_replaced_by_safe_fallback
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
        {
          "status" => "error", "exit_code" => 9,
          "provider" => "codex", "provider_failure" => "provider_error",
          "provider_provenance" => "codex_jsonl_transport"
        },
        stage: "4-review", task_generation: attempt.task_generation,
        attempt_id: attempt.attempt_id, recorded_at: NOW
      )
      secret = "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
      draft = JSON.parse(JSON.generate(draft))
      draft.fetch("provider")["provenance"] = secret
      worker = <<~RUBY
        diagnostic = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_DIAGNOSTIC_FD")), "w")
        diagnostic.write(#{JSON.generate("#{JSON.generate(draft)}\n")})
        diagnostic.close
        exit 9
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 9, Timeout.timeout(2) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "malformed", diagnostic.fetch("transport_status")
      assert_nil diagnostic.fetch("provider")
      refute_includes JSON.generate(diagnostic), secret
    end
  end

  def test_cancelled_patrol_attempt_synthesizes_diagnostic_when_frame_is_missing
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.03, kill_grace_sec: 0.03
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "sleep 10" ]
      end

      assert_equal 124, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      references = terminal.receipt.fetch("output_references")
      assert_equal 1, references.length
      diagnostic = JSON.parse(File.binread(File.join(store.root, references.fetch(0).fetch("path"))))
      assert_equal "agent_timeout", diagnostic.fetch("code")
      assert_equal true, diagnostic.fetch("timed_out")
      assert_equal true, diagnostic.fetch("cancelled")
      assert_equal "missing", diagnostic.fetch("transport_status")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_signalled_patrol_attempt_synthesizes_artifact_and_log_reference
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "2-fix",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        worker = <<~'RUBY'
          gate = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_GATE_FD")), "r")
          abort "gate not released" unless gate.read(1) == "1"
          Process.kill("KILL", Process.pid)
        RUBY
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 137, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      diagnostic = diagnostic_from_terminal(store, terminal)
      assert_equal "agent_signalled", diagnostic.fetch("code")
      assert_equal "KILL", diagnostic.fetch("signal")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_worker_killed_by_scope_oom_records_typed_memory_limit_reason
    worker_argv = [ "/bin/sh", "-c", "kill -KILL $$" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      counts = [ 2, 3 ]
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1,
        oom_kill_counter: -> { counts.shift }
      )

      assert_equal 137, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "failed", terminal.outcome
      log = attempt_log_text(store, terminal)
      assert_includes log, "failure_reason=memory_limit_exceeded oom_kills=1"
    end
  end

  def test_descendant_oom_kill_is_a_notice_when_the_worker_survives
    worker_argv = [ "/bin/sh", "-c", "exit 0" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      counts = [ 0, 2 ]
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1,
        oom_kill_counter: -> { counts.shift }
      )

      assert_equal 0, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      log = attempt_log_text(store, terminal)
      assert_includes log, "memory_limit_oom_kills=2"
      refute_includes log, "failure_reason="
    end
  end

  def test_unavailable_oom_counter_leaves_the_log_untouched
    with_attempt(worker_argv: [ "/bin/sh", "-c", "kill -KILL $$" ]) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1,
        oom_kill_counter: -> { nil }
      )

      assert_equal 137, Timeout.timeout(10) { supervisor.run }
      refute_includes attempt_log_text(store, store.fetch(attempt.attempt_id)), "memory_limit"
    end
  end

  def test_memory_limit_log_failures_do_not_break_terminalization
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new,
      oom_kill_counter: -> { 1 }
    )
    supervisor.instance_variable_set(:@worker_signal, "KILL")
    log = Object.new
    log.define_singleton_method(:append) { |*| raise IOError, "attempt log is closed" }

    assert_nil supervisor.send(:record_memory_limit_kills, 0, log)
    assert_equal "memory_limit_exceeded", supervisor.instance_variable_get(:@failure_reason)
  end

  def test_terminal_attempt_reaps_scope_leftovers_into_the_attempt_log
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 3" ]) do |store, attempt|
      reaper = recording_scope_reaper("reaped", reaped: [ { "pid" => 4242, "comm" => "conmon" } ])
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 0.3,
        scope_reaper: reaper
      )

      assert_equal 3, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "failed", terminal.outcome
      assert_equal [ 0.3 ], reaper.calls
      log = attempt_log_text(store, terminal)
      assert_includes log, "hive-attempt: scope_leftovers {"
      assert_includes log, '"comm":"conmon"'
    end
  end

  def test_clean_scope_leaves_the_attempt_log_untouched
    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 0" ]) do |store, attempt|
      reaper = recording_scope_reaper("clean")
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, scope_reaper: reaper
      )

      assert_equal 0, Timeout.timeout(10) { supervisor.run }
      assert_equal 1, reaper.calls.length
      refute_includes attempt_log_text(store, store.fetch(attempt.attempt_id)), "scope_leftovers"
    end
  end

  def test_unexpected_failure_still_reaps_scope_leftovers_before_the_receipt
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      reaper = recording_scope_reaper("incomplete", survivors: [ { "pid" => 7, "comm" => "stuck" } ])
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), scope_reaper: reaper
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "failed", terminal.outcome
      assert_equal 1, reaper.calls.length
      assert_includes attempt_log_text(store, terminal), '"status":"incomplete"'
    end
  end

  def test_scope_reaping_runs_on_early_exits_and_never_raises
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      reaper = Object.new
      calls = 0
      reaper.define_singleton_method(:reap) do |**|
        calls += 1
        raise Errno::EACCES, "cgroup"
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new("f" * 64), scope_reaper: reaper
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      assert_equal 1, calls
    end

    reaper = recording_scope_reaper("reaped")
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new, scope_reaper: reaper
    )
    closed_log = Object.new
    closed_log.define_singleton_method(:closed?) { true }
    closed_log.define_singleton_method(:append) { |*| flunk "a closed log must not be appended" }
    assert_nil supervisor.send(:reap_scope_leftovers, closed_log)
    assert_nil supervisor.send(:reap_scope_leftovers, closed_log)
    assert_equal 1, reaper.calls.length
  end

  def test_supervisor_defaults_to_a_reaper_for_its_own_attempt_scope
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new
    )

    assert_instance_of Hive::Attempts::ScopeReaper, supervisor.instance_variable_get(:@scope_reaper)
  end

  def test_attempt_worker_is_tagged_and_its_containers_reaped_before_the_scope
    print_override = [ "/bin/sh", "-c", 'printf "override=%s\n" "$CONTAINERS_CONF_OVERRIDE"' ]
    with_attempt(worker_argv: print_override) do |store, attempt|
      order = []
      podman = container_podman([ [ podman_container("todero-test-pg") ], [] ], order)
      scope = recording_scope_reaper("clean")
      scope.define_singleton_method(:reap) { |**| order << :scope; Hive::Attempts::ScopeReaper::Result.new(
        status: "clean", unit: "u", reaped: [], survivors: [], error: nil
      ) }
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 0.3,
        scope_reaper: scope, container_reaper: container_reaper(podman)
      )

      assert_equal 0, Timeout.timeout(10) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      conf = File.join(store.output_directory(attempt.attempt_id, "containers"), "containers.conf")
      assert_includes File.read(conf), '"hive.attempt=attempt-1"'
      assert_includes File.read(conf), '"hive.project=demo"'
      log = attempt_log_text(store, terminal)
      assert_includes log, "override=#{conf}\n"
      assert_includes log, "hive-attempt: attempt_containers {"
      assert_includes log, '"name":"todero-test-pg"'
      assert_equal "annotation=hive.attempt=attempt-1", podman.calls.first.first[4]
      assert_equal %i[ps rm ps scope], order
    end
  end

  def test_container_reap_failures_never_change_the_attempt_outcome
    [
      ->(_argv, _timeout) { Hive::Attempts::ContainerReaper::Command.new(status: :timeout, output: "") },
      ->(_argv, _timeout) { raise IOError, "podman pipe" }
    ].each do |runner|
      with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 0" ]) do |store, attempt|
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
          stale_sec: 1, first_heartbeat_timeout_sec: 1,
          scope_reaper: recording_scope_reaper("clean"),
          container_reaper: Hive::Attempts::ContainerReaper.new(
            attempt_id: attempt.attempt_id, runner: runner, environment: {}
          )
        )

        assert_equal 0, Timeout.timeout(10) { supervisor.run }
        terminal = store.fetch(attempt.attempt_id)
        assert_equal "succeeded", terminal.outcome
        assert_equal 0, terminal.receipt.fetch("exit_status")
        assert_includes attempt_log_text(store, terminal), '"status":"failed"'
      end
    end

    with_attempt(worker_argv: [ "/bin/sh", "-c", "exit 4" ]) do |store, attempt|
      exploding = Object.new
      exploding.define_singleton_method(:tag) do |**|
        Hive::Attempts::ContainerReaper::Tagging.new(status: "tagged", environment: {}, error: nil)
      end
      exploding.define_singleton_method(:reap) { |**| raise "reaper bug" }
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1,
        scope_reaper: recording_scope_reaper("clean"), container_reaper: exploding
      )

      assert_equal 4, Timeout.timeout(10) { supervisor.run }
      assert_equal "failed", store.fetch(attempt.attempt_id).outcome
    end
  end

  def test_project_opt_out_neither_tags_nor_reaps_containers
    print_override = [ "/bin/sh", "-c", 'printf "override=[%s]\n" "$CONTAINERS_CONF_OVERRIDE"' ]
    with_attempt(worker_argv: print_override) do |store, attempt|
      podman = container_podman([], [])
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1,
        scope_reaper: recording_scope_reaper("clean"),
        container_reaper: container_reaper(podman), reap_containers: false
      )

      with_env("CONTAINERS_CONF_OVERRIDE" => nil) do
        assert_equal 0, Timeout.timeout(10) { supervisor.run }
      end
      terminal = store.fetch(attempt.attempt_id)
      log = attempt_log_text(store, terminal)
      assert_includes log, "override=[]\n"
      refute_includes log, "attempt_containers"
      assert_empty podman.calls
      refute File.exist?(File.join(store.output_directory(attempt.attempt_id, "containers"), "containers.conf"))
    end
  end

  def test_an_operator_containers_conf_override_is_kept_and_logged_untagged
    print_override = [ "/bin/sh", "-c", 'printf "override=%s\n" "$CONTAINERS_CONF_OVERRIDE"' ]
    with_attempt(worker_argv: print_override) do |store, attempt|
      podman = container_podman([], [])
      with_env("CONTAINERS_CONF_OVERRIDE" => "/etc/operator-containers.conf") do
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
          stale_sec: 1, first_heartbeat_timeout_sec: 1,
          scope_reaper: recording_scope_reaper("clean"),
          container_reaper: Hive::Attempts::ContainerReaper.new(attempt_id: attempt.attempt_id, runner: podman)
        )

        assert_equal 0, Timeout.timeout(10) { supervisor.run }
      end
      log = attempt_log_text(store, store.fetch(attempt.attempt_id))
      assert_includes log, "override=/etc/operator-containers.conf\n"
      assert_includes log, '"status":"untagged"'
      assert_empty podman.calls
    end
  end

  def test_an_unavailable_attempt_directory_leaves_the_worker_untagged_and_logged
    store = Object.new
    store.define_singleton_method(:output_directory) do |*|
      raise Hive::Attempts::RepositoryError, "attempt output directory is unavailable"
    end
    supervisor = Hive::Attempts::Supervisor.new(
      store: store, attempt_id: "attempt-1", claim_io: StringIO.new,
      container_reaper: container_reaper(container_podman([], []))
    )
    record = { "project" => "demo" }
    record.define_singleton_method(:attempt_id) { "attempt-1" }

    assert_equal({}, supervisor.send(:container_environment, record))
    lines = []
    log = Object.new
    log.define_singleton_method(:closed?) { false }
    log.define_singleton_method(:append) { |channel, line| lines << [ channel, line ] }
    supervisor.send(:reap_attempt_containers, log)

    assert_equal :supervisor, lines.fetch(0).first
    assert_includes lines.fetch(0).last, '"status":"untagged"'
    assert_includes lines.fetch(0).last, "attempt output directory is unavailable"
  end

  def test_supervisor_skips_the_container_reap_when_no_worker_was_tagged
    reaper = Object.new
    reaper.define_singleton_method(:reap) { |**| flunk "an untagged attempt must not run podman" }
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new, container_reaper: reaper
    )

    assert_nil supervisor.send(:reap_attempt_containers, nil)
    assert_instance_of Hive::Attempts::ContainerReaper,
                       Hive::Attempts::Supervisor.new(
                         store: Object.new, attempt_id: "attempt-1", claim_io: StringIO.new
                       ).instance_variable_get(:@container_reaper)
  end

  def test_signalled_patrol_attempt_reports_memory_limit_agent_reason
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "2-fix",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      counts = [ 0, 1 ]
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1,
        oom_kill_counter: -> { counts.shift }
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        worker = <<~'RUBY'
          gate = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_GATE_FD")), "r")
          abort "gate not released" unless gate.read(1) == "1"
          Process.kill("KILL", Process.pid)
        RUBY
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 137, Timeout.timeout(10) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "memory_limit_exceeded", diagnostic.fetch("agent_reason")
      assert_equal "KILL", diagnostic.fetch("signal")
    end
  end

  def test_cancel_signal_synthesizes_cancelled_artifact_and_log_reference
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "2-fix",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ "/bin/sh", "-c", "exec sleep 10" ]
      end
      supervisor.instance_variable_set(:@cancel_reason, :signal)
      supervisor.instance_variable_set(:@cancel_signal, "TERM")

      assert_equal 143, Timeout.timeout(3) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      diagnostic = diagnostic_from_terminal(store, terminal)
      assert_equal "agent_cancelled", diagnostic.fetch("code")
      assert_equal true, diagnostic.fetch("cancelled")
      assert_equal "TERM", diagnostic.fetch("signal")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_timeout_and_heartbeat_continue_while_descendant_holds_output_pipe
    worker_argv = [
      "/bin/sh", "-c",
      "trap '' TERM; (exec sleep 10) & printf 'leader-exited\\n'; exit 0"
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

  def test_one_shot_log_sync_failure_keeps_writer_open_for_diagnostic_terminalization
    %i[flush fsync].each do |operation|
      with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
        original = store.log_archive.method(:open_writer)
        captured_log = nil
        error = IOError.new("#{operation} failed")
        store.log_archive.define_singleton_method(:open_writer) do |attempt_id, clock:|
          captured_log = original.call(attempt_id, clock: clock)
          fault = AttemptsSupervisorTest::OneShotSyncFaultWriter.new(
            captured_log.instance_variable_get(:@io), operation: operation, error: error
          )
          captured_log.instance_variable_set(:@io, fault)
          captured_log
        end
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
          stale_sec: 1, first_heartbeat_timeout_sec: 1
        )

        assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
        terminal = store.fetch(attempt.attempt_id)
        frames = Hive::Attempts::StreamLog.read(
          File.join(store.root, terminal.receipt.dig("log_reference", "path"))
        )
        assert_equal "terminal", terminal.state
        assert_equal "failed", terminal.outcome
        assert_match(/#{operation} failed/, frames.last.bytes)
        assert captured_log.closed?
      end
    end
  end

  def test_one_shot_separator_error_during_drain_is_fatal_and_diagnostic_recovers
    worker_argv = [ "/bin/sh", "-c", "printf worker-output; sleep 10" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      injection = inject_torn_log_separator_failure(store.log_archive, persistent: false)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 0.05
      )
      terminations = observe_worker_termination(supervisor)

      assert_equal Hive::ExitCodes::SOFTWARE, Timeout.timeout(3) { supervisor.run }

      terminal = store.fetch(attempt.attempt_id)
      frames = Hive::Attempts::StreamLog.read(
        File.join(store.root, terminal.receipt.dig("log_reference", "path"))
      )
      assert_equal "terminal", terminal.state
      assert_equal "failed", terminal.outcome
      assert_equal Hive::ExitCodes::SOFTWARE, terminal.receipt.fetch("exit_status")
      assert_operator terminations.call, :>=, 1
      refute supervisor.send(:recorded_worker_group_alive?)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal %w[supervisor supervisor], frames.map(&:channel)
      assert_equal "existing\n", frames.first.bytes
      assert_match(/hive attempt supervisor failed: Errno::EINTR/, frames.last.bytes)
      refute_includes frames.map(&:bytes).join, "worker-output"
      assert_equal 2, injection.fetch(:fault).separator_attempts
      assert injection.fetch(:log).closed?
    end
  end

  def test_persistent_separator_error_during_drain_leaves_running_attempt_for_lost_recovery
    worker_argv = [ "/bin/sh", "-c", "printf worker-output; sleep 10" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      archive = store.log_archive
      injection = inject_torn_log_separator_failure(archive, persistent: true)
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 0.05
      )
      terminations = observe_worker_termination(supervisor)

      assert_equal Hive::ExitCodes::SOFTWARE, Timeout.timeout(3) { supervisor.run }

      current = store.fetch(attempt.attempt_id)
      frames = Hive::Attempts::StreamLog.read(archive.hot_path(attempt.attempt_id))
      assert_equal "running", current.state
      assert_nil current.receipt
      assert_nil current["log_reference"]
      assert_empty current["current_outputs"]
      assert_operator terminations.call, :>=, 1
      refute supervisor.send(:recorded_worker_group_alive?)
      assert_equal [ "existing\n" ], frames.map(&:bytes)
      refute_includes frames.map(&:bytes).join, "worker-output"
      assert_equal 2, injection.fetch(:fault).separator_attempts
      assert injection.fetch(:log).closed?
      error = assert_raises(Hive::Attempts::RepositoryError) do
        archive.archive(attempt.attempt_id)
      end
      assert_match(/only final attempt payloads/, error.message)
    end
  end

  def test_unexpected_patrol_supervisor_failure_still_binds_synthetic_diagnostic
    with_attempt(
      worker_argv: [ "hive", "run", "durable-task" ], intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      reference = terminal.receipt.fetch("output_references").fetch(0)
      diagnostic = JSON.parse(File.binread(File.join(store.root, reference.fetch("path"))))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal "missing", diagnostic.fetch("transport_status")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_secondary_failure_during_unexpected_error_is_contained
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      original_fetch = store.method(:fetch)
      fetches = 0
      store.define_singleton_method(:fetch) do |attempt_id, **options|
        fetches += 1
        raise "store unavailable" if fetches > 1

        original_fetch.call(attempt_id, **options)
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
    assert_equal [ RbConfig.ruby, File.expand_path("../../../bin/hive", __dir__), "--context", "local", "run", "task" ],
                 supervisor.send(:resolved_worker_argv, record)
    assert_equal [ "hive", "run", "task" ], record.fetch("worker_argv")

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { raise Errno::ESRCH }) do
      assert_raises(Hive::Attempts::RepositoryError) { supervisor.send(:process_identity, 99) }
    end
  end

  def test_worker_termination_escalation_and_signal_setup_are_defensive
    ticks = [ 0.0, 0.0, 0.01 ]
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

    trapped = {}
    with_replaced_singleton_method(Signal, :trap, ->(signal, &block) { trapped[signal] = block }) do
      supervisor.send(:install_signal_handlers!)
    end
    assert_equal %w[INT TERM], trapped.keys.sort
    trapped.fetch("TERM").call
    assert_equal "TERM", supervisor.instance_variable_get(:@cancel_signal)
    assert_equal :signal, supervisor.instance_variable_get(:@cancel_reason)

    ready = Object.new
    ready.define_singleton_method(:closed?) { false }
    ready.define_singleton_method(:write) { |_bytes| raise Errno::EPIPE }
    supervisor.instance_variable_set(:@ready_io, ready)
    supervisor.send(:signal_ready, "claimed" => true)
    assert_equal true, supervisor.instance_variable_get(:@ready_sent)

    supervisor.singleton_class.send(:remove_method, :signal_worker_group)
    supervisor.instance_variable_set(:@worker_pgid, 456)
    with_replaced_singleton_method(Process, :getpgid, ->(_pid) { 999 }) do
      assert_raises(Hive::Attempts::RepositoryError) { supervisor.send(:signal_worker_group, "TERM") }
    end
    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      refute supervisor.send(:signal_recorded_worker_group, "TERM")
    end
    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_raises(Hive::Attempts::RepositoryError) do
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

  def recording_scope_reaper(status, reaped: [], survivors: [])
    reaper = Object.new
    calls = []
    result = Hive::Attempts::ScopeReaper::Result.new(
      status: status, unit: "hive-attempt-test.scope", reaped: reaped, survivors: survivors, error: nil
    )
    reaper.define_singleton_method(:calls) { calls }
    reaper.define_singleton_method(:reap) do |term_grace_sec:|
      calls << term_grace_sec
      result
    end
    reaper
  end

  def podman_container(name)
    { "Id" => Digest::SHA256.hexdigest(name), "Names" => [ name ], "Image" => "docker.io/library/postgres:16",
      "State" => "running" }
  end

  def container_podman(listings, order)
    calls = []
    runner = lambda do |argv, timeout|
      calls << [ argv, timeout ]
      order << argv[1].to_sym
      next Hive::Attempts::ContainerReaper::Command.new(status: :ok, output: "") if argv[1] == "rm"

      Hive::Attempts::ContainerReaper::Command.new(status: :ok, output: JSON.generate(listings.shift || []))
    end
    runner.define_singleton_method(:calls) { calls }
    runner
  end

  def container_reaper(runner)
    Hive::Attempts::ContainerReaper.new(attempt_id: "attempt-1", runner: runner, environment: {})
  end

  def attempt_log_text(store, terminal)
    Hive::Attempts::StreamLog.read(
      File.join(store.root, terminal.receipt.dig("log_reference", "path"))
    ).map(&:bytes).join
  end

  def inject_torn_log_separator_failure(archive, persistent:)
    original = archive.method(:open_writer)
    seed_torn = method(:seed_torn_tail)
    injection = {}
    archive.define_singleton_method(:open_writer) do |attempt_id, clock:|
      log = original.call(attempt_id, clock: clock)
      log.append(:supervisor, "existing\n")
      seed_torn.call(log.path)
      fault = AttemptsSupervisorTest::SeparatorFaultWriter.new(
        log.instance_variable_get(:@io), persistent: persistent
      )
      log.instance_variable_set(:@io, fault)
      injection[:log] = log
      injection[:fault] = fault
      log
    end
    injection
  end

  def observe_worker_termination(supervisor)
    calls = 0
    original = supervisor.method(:terminate_worker_group)
    supervisor.define_singleton_method(:terminate_worker_group) do
      calls += 1
      original.call
    end
    -> { calls }
  end

  def diagnostic_from_terminal(store, terminal)
    reference = terminal.receipt.fetch("output_references").find do |candidate|
      File.basename(candidate.fetch("path")) == Hive::PatrolFix::AttemptDiagnostic::FILENAME
    end
    JSON.parse(File.binread(File.join(store.root, reference.fetch("path"))))
  end

  def with_sql_holder(store, seconds:)
    reader, writer = IO.pipe
    script = <<~'RUBY'
      connection = SQLite3::Database.new(ARGV.fetch(0))
      connection.execute("BEGIN IMMEDIATE")
      writer = IO.for_fd(Integer(ARGV.fetch(2)))
      writer.write("1")
      writer.close
      sleep Float(ARGV.fetch(1))
      connection.execute("ROLLBACK")
      connection.close
    RUBY
    holder = Process.spawn(
      RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-rsqlite3", "-e", script,
      store.database.path, seconds.to_s, writer.fileno.to_s,
      writer.fileno => writer.fileno, close_others: true
    )
    writer.close
    assert_equal "1", reader.read(1)
    yield
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    Process.wait(holder) if holder
  end

  def with_attempt(worker_argv:, routing: { "mode" => "legacy" }, intended_stage: "4-execute",
                   workflow_controller: nil)
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      attempt = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1",
        task_id: "42", project: "demo", task_slug: "durable-task",
        intended_stage: intended_stage, task_generation: "generation-1",
        progress_token: "progress-1", provider: "codex", worker_argv: worker_argv,
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY), starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], routing: routing,
        launch_timeout_sec: 30, now: Time.now.utc
      )
      unless workflow_controller
        yield store, attempt
        next
      end

      workflow = Struct.new(:controller).new(workflow_controller)
      task = Struct.new(:workflow).new(workflow)
      resolver = Object.new
      resolver.define_singleton_method(:resolve) { task }
      with_replaced_singleton_method(
        Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }
      ) { yield store, attempt }
    end
  end

  def explicit_routing
    {
      "mode" => "explicit",
      "route" => {
        "route_id" => "account-a/model-a", "provider_account_id" => "account-a",
        "adapter" => "codex", "launch_binding_id" => "default",
        "model" => "model-a", "effort" => "high"
      }
    }
  end
end
