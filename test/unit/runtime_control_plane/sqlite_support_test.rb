require "test_helper"
require "hive/runtime_control_plane"

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
end
