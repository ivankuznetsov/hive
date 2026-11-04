require "test_helper"
require "hive/attempts/bookkeeping_retry"

class AttemptsBookkeepingRetryTest < Minitest::Test
  def retryer(budget: 30, deadline: nil, operation: "claim")
    @now ||= 0.0
    @sleeps ||= []
    Hive::Attempts::BookkeepingRetry.new(
      operation: operation, attempt_id: "attempt-1", budget_sec: budget, deadline: deadline,
      monotonic: -> { @now }, sleeper: ->(seconds) { @sleeps << seconds; @now += seconds },
      random: -> { 0.5 }
    )
  end

  def test_busy_exhaustion_is_typed_and_exactly_bounded_by_one_deadline
    retries = retryer
    timeouts = []
    error = assert_raises(Hive::Attempts::BookkeepingBusy) do
      retries.run do |timeout|
        timeouts << timeout
        @now += timeout
        raise SQLite3::BusyException, "busy"
      end
    end
    assert_equal 30, @now
    assert_equal "claim", error.operation
    assert_equal "attempt-1", error.attempt_id
    assert_equal timeouts.length, error.retry_count
    assert_equal 30, error.elapsed_sec
    assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
    assert timeouts.all? { |timeout| timeout.positive? && timeout <= 1 }
  end

  def test_renewal_and_terminal_envelopes_can_succeed_beyond_thirty_seconds
    %w[heartbeat terminalize].each do |operation|
      @now = 0.0
      retries = retryer(budget: 600, operation: operation)
      result = retries.run do |timeout|
        @now += timeout
        raise SQLite3::BusyException, "busy" if @now <= 35
        :saved
      end
      assert_equal :saved, result
      assert_operator @now, :>, 30
      assert_operator @now, :<, 600
      assert_equal 600, retries.deadline
    end
  end

  def test_scheduled_retries_never_reset_the_deadline_or_stop_after_twelve_tries
    retries = retryer(budget: 600)
    40.times do
      assert_nil retries.try { raise SQLite3::BusyException, "busy" }
      @now += retries.delay
    end
    assert_equal 600, retries.deadline
    @now = 600
    assert_raises(Hive::Attempts::BookkeepingBusy) { retries.try { flunk "expired try" } }
    assert_equal 40, retries.retry_count
  end

  def test_last_try_has_a_positive_remaining_wait_and_cannot_overshoot
    retries = retryer(deadline: 0.025)
    timeouts = []
    assert_raises(Hive::Attempts::BookkeepingBusy) do
      retries.run do |timeout|
        timeouts << timeout
        @now += timeout
        raise SQLite3::BusyException, "busy"
      end
    end
    assert_equal [ 0.025 ], timeouts
    assert_equal 0.025, @now
  end

  def test_lifecycle_deadline_is_converted_once_and_strictly_inside_expiry
    retries = retryer
    retries.cap_lifecycle!(expires_at: Time.at(5), now: Time.at(0))
    first_deadline = retries.deadline
    assert_operator first_deadline, :<, 5
    @now = 2
    retries.cap_lifecycle!(expires_at: Time.at(30), now: Time.at(2))
    assert_equal first_deadline, retries.deadline
    assert_raises(Hive::Attempts::BookkeepingBusy) do
      retries.cap_lifecycle!(expires_at: Time.at(2), now: Time.at(2))
    end
  end

  def test_nonbusy_and_cas_errors_are_not_retried
    [ RuntimeError.new("database is locked"), Hive::Attempts::CompareAndSwapFailed.new("CAS") ].each do |error|
      retries = retryer
      assert_same error, assert_raises(error.class) { retries.run { raise error } }
      assert_empty @sleeps
    end
  end

  def test_wrapped_busy_codes_fences_and_cycles
    busy = SQLite3::Exception.new("snapshot")
    busy.define_singleton_method(:code) { 517 }
    sequel = Sequel::DatabaseError.new("wrapped")
    sequel.wrapped_exception = busy
    assert Hive::Attempts::BookkeepingRetry.busy?(sequel)
    assert Hive::Attempts::BookkeepingRetry.busy?(Hive::RuntimeControlPlane::FileFence::Busy.new("fence", lock_path: "/fence"))
    refute Hive::Attempts::BookkeepingRetry.busy?(Hive::ConcurrentRunError.new("unrelated"))
    cycle = RuntimeError.new("database is locked")
    cycle.define_singleton_method(:cause) { self }
    refute Hive::Attempts::BookkeepingRetry.busy?(cycle)
    refute Hive::InternalError.sqlite_busy?(cycle)
    assert Hive::InternalError.sqlite_busy?(sequel)
  end

  def test_nested_calls_share_deadline_and_preserve_outer_launch_scope
    retries = retryer(budget: 600)
    Hive::Attempts::BookkeepingRetry.with_launch_deadline(retries.deadline) do
      Hive::Attempts::BookkeepingRetry.with_launch_deadline(900) do
        assert_equal 600, Hive::Attempts::BookkeepingRetry.launch_deadline
        nested = retryer(budget: 600, deadline: retries.deadline)
        @now = 599.95
        assert_raises(Hive::Attempts::BookkeepingBusy) do
          nested.run { |timeout| @now += timeout; raise SQLite3::BusyException, "busy" }
        end
        assert_equal 600, @now
      end
      assert_equal 600, Hive::Attempts::BookkeepingRetry.launch_deadline
    end
    assert_nil Hive::Attempts::BookkeepingRetry.launch_deadline
    assert_nil retryer.cap_lifecycle!(expires_at: nil, now: Time.at(0)).run { nil }
    assert_operator retries.diagnostic_try_bound, :>, 12
    assert_operator retries.delay, :<=, 1.0
  end

  def test_six_hundred_second_exhaustion_is_not_a_thirty_second_batch_loop
    retries = retryer(budget: 600, operation: "terminalize")
    error = assert_raises(Hive::Attempts::BookkeepingBusy) do
      retries.run { |timeout| @now += timeout; raise SQLite3::BusyException, "busy" }
    end
    assert_equal 600, @now
    assert_equal 600, error.budget_sec
    assert_operator error.retry_count, :>, 12
    assert_instance_of SQLite3::BusyException, error.cause
  end

  def test_configured_prestart_budget_cannot_extend_the_fixed_thirty_second_cap
    assert_equal 30, Hive::Attempts::BookkeepingRetry.prestart_budget(60)
    retries = retryer(budget: Hive::Attempts::BookkeepingRetry.prestart_budget(60))
    retries.cap_lifecycle!(expires_at: Time.at(60), now: Time.at(0))
    assert_equal 30, retries.deadline
    assert_equal 2.5, Hive::Attempts::BookkeepingRetry.prestart_budget(2.5)
    [ 0, -1, Float::INFINITY, Float::NAN ].each do |value|
      assert_raises(ArgumentError) { Hive::Attempts::BookkeepingRetry.prestart_budget(value) }
    end
  end

  def test_nested_operations_spend_the_same_single_try_allowance
    retries = retryer(budget: 30)
    retries.try do |timeout|
      assert_equal 1.0, timeout
      @now = 0.75
      assert_equal 0.25, retries.timeout_sec
      @now = 1.0
      retries.timeout_sec
    end
    assert_equal 1, retries.retry_count
    assert_equal 30, retries.deadline
    assert_equal :saved, retries.try { :saved }
  end

  def test_pre_admission_exhaustion_has_no_attempt_identity
    retries = Hive::Attempts::BookkeepingRetry.new(
      operation: "admission", deadline: 0, monotonic: -> { 0.0 }
    )
    error = assert_raises(Hive::Attempts::BookkeepingBusy) { retries.run { flunk "expired admission" } }
    assert_nil error.attempt_id
    assert_equal 0, error.retry_count
    assert_equal "runtime_bookkeeping_busy", error.reason
  end

  def test_invalid_budgets_are_rejected
    [ 0, -1, Float::INFINITY, Float::NAN ].each do |budget|
      assert_raises(ArgumentError) { retryer(budget: budget) }
    end
  end

  def test_busy_failure_rejects_an_unknown_reason
    error = assert_raises(ArgumentError) do
      Hive::Attempts::BookkeepingBusy.new(
        operation: "claim", attempt_id: nil, retry_count: 0,
        elapsed_sec: 0, budget_sec: 30, reason: "provider_failure"
      )
    end
    assert_equal "unsupported bookkeeping failure reason", error.message
  end
end
