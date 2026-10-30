require "test_helper"
require "hive/runtime_control_plane"

class RuntimeContentionBudgetTest < Minitest::Test
  Budget = Hive::RuntimeControlPlane::ContentionBudget

  def test_default_clock_and_wait_exhaust_the_busy_budget
    budget = Budget.new(seconds: 0.001)
    refute budget.retry_busy
    assert_operator budget.waited, :>=, 0.001
    refute budget.retry_busy
  end

  def test_waiting_is_shared_and_computation_is_free
    now = 0.0
    budget = Budget.new(seconds: 0.025, clock: -> { now }, wait: ->(time) { now += time })
    assert budget.retry_busy
    now += 100 # unrelated work
    assert budget.retry_busy
    refute budget.retry_busy
    refute budget.retry_busy
    assert_in_delta 0.025, budget.waited
  end

  def test_sub_resolution_wait_terminates_without_spinning
    budget = Budget.new(clock: -> { 0.0 }, wait: ->(_) { })
    refute budget.retry_busy
    refute budget.retry_busy
    assert_equal 0, budget.waited
  end

  def test_scope_nests_and_clears_on_exception
    assert_nil Budget.current
    assert_raises(RuntimeError) do
      Budget.with do |outer|
        Budget.with { |inner| assert_same outer, inner }
        raise "test"
      end
    end
    assert_nil Budget.current
    Budget.with { |fresh| assert_equal 0, fresh.waited }
  end

  def test_only_busy_errors_are_classified
    support = Hive::RuntimeControlPlane::SQLiteSupport
    typed = Hive::RuntimeControlPlane::Busy.new
    assert support.busy_error?(typed)
    assert_same typed, assert_raises(Hive::RuntimeControlPlane::Busy) { support.raise_if_busy!(typed) }
    assert support.busy_error?(SQLite3::BusyException.new)
    wrapped = begin
      raise SQLite3::BusyException
    rescue SQLite3::BusyException
      begin
        raise Sequel::DatabaseError
      rescue Sequel::DatabaseError => error
        error
      end
    end
    assert support.busy_error?(wrapped)
    [ SQLite3::CorruptException, SQLite3::ReadOnlyException, SQLite3::CantOpenException,
     Sequel::DatabaseError ].each { |type| refute support.busy_error?(type.new) }
    busy = assert_raises(Hive::RuntimeControlPlane::Busy) { support.raise_if_busy!(wrapped) }
    assert_equal 75, busy.exit_code
    assert_equal :runtime_database_busy, busy.code
  end
end
