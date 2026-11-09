require "test_helper"
require "hive/runtime_control_plane"
require "timeout"

class RuntimeSQLiteSupportTest < Minitest::Test
  include HiveTestHelper

  def test_table_probe_distinguishes_present_and_missing_tables
    connection = Sequel.sqlite
    connection.create_table(:present) { Integer :id }

    assert Hive::RuntimeControlPlane::SQLiteSupport.table_exists?(connection, :present)
    refute Hive::RuntimeControlPlane::SQLiteSupport.table_exists?(connection, :missing)
  ensure
    connection&.disconnect
  end

  def test_table_probe_propagates_real_sqlite_contention
    with_tmp_dir do |root|
      path = File.join(root, "locked.sqlite3")
      connection = Sequel.sqlite(path, timeout: 0)
      connection.create_table(:present) { Integer :id }
      locker = SQLite3::Database.new(path)
      locker.execute("BEGIN EXCLUSIVE")

      error = assert_raises(Sequel::DatabaseError) do
        Hive::RuntimeControlPlane::SQLiteSupport.table_exists?(connection, :present)
      end
      assert Hive::RuntimeControlPlane::SQLiteSupport.busy_error?(error)

      locker.execute("ROLLBACK")
      assert Hive::RuntimeControlPlane::SQLiteSupport.table_exists?(connection, :present)
    ensure
      locker&.close
      connection&.disconnect
    end
  end

  def test_busy_error_classifies_direct_and_wrapped_busy_errors
    busy = SQLite3::BusyException.new("database is locked")

    assert support.busy_error?(busy)
    assert support.busy_error?(chain(StandardError.new("outer"), busy))
    assert support.busy_error?(Sequel::DatabaseLockTimeout.new("lock timeout"))
    assert support.busy_error?(Hive::RuntimeControlPlane::Busy.new)
    refute support.busy_error?(StandardError.new("plain"))
    refute support.busy_error?(chain(StandardError.new("outer"), RuntimeError.new("inner")))
    refute support.busy_error?(nil)
  end

  def test_storage_exhaustion_classification_is_unchanged
    assert support.storage_exhaustion_error?(chain(StandardError.new("outer"), Errno::ENOSPC.new))
    assert support.storage_exhaustion_error?(SQLite3::FullException.new("full"))
    assert support.storage_exhaustion_error?(Errno::EDQUOT.new)
    refute support.storage_exhaustion_error?(StandardError.new("plain"))
  end

  def test_busy_error_terminates_on_self_referential_cause
    error = StandardError.new("self")
    error.define_singleton_method(:cause) { error }

    Timeout.timeout(5) do
      refute support.busy_error?(error)
      refute support.storage_exhaustion_error?(error)
    end
  end

  def test_busy_error_terminates_on_two_node_cycle
    first = StandardError.new("first")
    second = StandardError.new("second")
    first.define_singleton_method(:cause) { second }
    second.define_singleton_method(:cause) { first }

    Timeout.timeout(5) { refute support.busy_error?(first) }
  end

  def test_busy_error_still_found_before_a_cycle_closes
    busy = SQLite3::BusyException.new("database is locked")
    first = StandardError.new("first")
    first.define_singleton_method(:cause) { busy }
    busy.define_singleton_method(:cause) { first }

    Timeout.timeout(5) { assert support.busy_error?(first) }
  end

  def test_busy_error_walk_is_bounded_by_max_cause_depth
    limit = Hive::RuntimeControlPlane::SQLiteSupport::MAX_CAUSE_DEPTH
    busy = SQLite3::BusyException.new("database is locked")

    assert support.busy_error?(wrapped(busy, limit - 1))
    Timeout.timeout(5) { refute support.busy_error?(wrapped(busy, limit)) }
  end

  private

  def support
    Hive::RuntimeControlPlane::SQLiteSupport
  end

  def chain(outer, inner)
    outer.define_singleton_method(:cause) { inner }
    outer
  end

  def wrapped(error, layers)
    layers.times.reduce(error) { |inner, index| chain(StandardError.new("layer #{index}"), inner) }
  end
end
