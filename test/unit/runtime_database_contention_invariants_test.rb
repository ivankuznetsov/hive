require "test_helper"
require_relative "../support/runtime_contention_attempt_fixture"

class RuntimeDatabaseContentionInvariantsTest < Minitest::Test
  include HiveTestHelper
  include RuntimeContentionAttemptFixture

  def test_prestart_and_live_operation_envelopes_do_not_reset_on_nested_busy
    { "claim" => 30, "first_heartbeat" => 30, "checkpoint" => 600,
      "heartbeat" => 600, "terminalize" => 600 }.each do |operation, budget|
      [ false, true ].each do |exhaust|
        mono = 0.0
        observed = []
        nested_allowances = []
        retrying = Hive::Attempts::BookkeepingRetry.new(
          operation: operation, budget_sec: budget, monotonic: -> { mono },
          sleeper: ->(seconds) { mono += seconds }, random: -> { 0.5 }
        )
        action = lambda do
          retrying.run do |timeout|
            observed << timeout
            # Model a nested read spending most of the SAME SQL try.
            mono += timeout * 0.75
            nested = retrying.timeout_sec
            nested_allowances << [ nested, timeout ]
            mono += nested
            raise SQLite3::BusyException, "held writer" if exhaust || mono < budget - 2
            :committed
          end
        end
        if exhaust
          error = assert_raises(Hive::Attempts::BookkeepingBusy, &action)
          assert_equal "runtime_bookkeeping_busy", error.reason
          assert_in_delta budget, error.elapsed_sec, 0.000001
        else
          assert_equal :committed, action.call
          assert_operator mono, :>, 30 if budget == 600
        end
        assert_operator mono, :<=, budget
        assert observed.all? { |timeout| timeout.positive? && timeout <= 1 }
        assert nested_allowances.all? { |nested, timeout| nested <= timeout * 0.25 + 0.000001 }
      end
    end
  end

  def test_restarted_reconciler_replays_completion_once_before_releasing_capacity
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      attempt = create_contention_attempt(store, id: "restart")
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(RuntimeContentionAttemptFixture::SECRET)
      )
      # Crash boundary: immutable completion exists, SQL terminal write has not run.
      store.define_singleton_method(:terminalize) do |*, **|
        raise Hive::Attempts::BookkeepingBusy.new(
          operation: "terminalize", attempt_id: attempt.attempt_id,
          retry_count: 1, elapsed_sec: 600, budget_sec: 600
        )
      end
      capture_io { supervisor.run }
      current = store.fetch(attempt.attempt_id)
      assert_equal "running", current.state
      assert_equal :valid, store.pending_bookkeeping.read(current).status
      path = store.database.path
      store.database.disconnect
      database = Hive::RuntimeControlPlane::Database.new(path: path)
      restarted = Hive::Attempts::Repository.new(root: root, database: database)
      identity = Object.new
      identity.define_singleton_method(:status) { |_| :missing }
      identity.define_singleton_method(:orphan_group_status) { |**| :absent }
      2.times do
        snapshot = Hive::Attempts::Reconciler.new(store: restarted, process_identity: identity).reconcile
        assert_empty snapshot.newly_lost_attempts
        assert_equal 0, snapshot.capacity.global_count
        assert_equal "succeeded", restarted.fetch(attempt.attempt_id).outcome
      end
      assert_equal 1, database.read { |db| db[:attempts].count }
    ensure
      database&.disconnect
      store&.database&.disconnect
    end
  end
end
