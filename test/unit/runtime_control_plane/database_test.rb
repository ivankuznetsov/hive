require "test_helper"
require "hive/runtime_control_plane"

class RuntimeControlPlaneDatabaseTest < Minitest::Test
  include HiveTestHelper

  def teardown
    Hive::RuntimeControlPlane.disconnect
    super
  end

  def test_explicit_migration_creates_exact_database_and_normal_open_is_lazy
    with_tmp_dir do |root|
      path = File.join(root, "state", "runtime-control-plane.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      refute_path_exists path
      assert_equal :missing, database.diagnostics.status
      refute_path_exists path, "validation-only calls must not create SQLite state"

      database.migrate!

      assert_path_exists path
      diagnosis = database.diagnostics
      assert_equal :ok, diagnosis.status
      assert_equal Hive::RuntimeControlPlane::SCHEMA_VERSION, diagnosis.schema_version
      assert_equal Hive::RuntimeControlPlane::APPLICATION_ID, diagnosis.application_id
      assert_equal 1, database.read { |connection| connection[:installations].count }
    end
  end

  def test_live_connections_use_the_required_sqlite_settings
    with_database do |database|
      settings = database.read do |connection|
        pragma = ->(name) { connection.fetch("PRAGMA #{name}").first.values.first }
        {
          journal_mode: pragma.call("journal_mode").to_s.downcase,
          foreign_keys: pragma.call("foreign_keys"),
          synchronous: pragma.call("synchronous"),
          trusted_schema: pragma.call("trusted_schema"),
          busy_timeout_ms: pragma.call("busy_timeout")
        }
      end

      assert_equal "wal", settings.fetch(:journal_mode)
      assert_equal 1, settings.fetch(:foreign_keys)
      assert_equal 2, settings.fetch(:synchronous)
      assert_equal 0, settings.fetch(:trusted_schema)
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   settings.fetch(:busy_timeout_ms)
      assert_raises(Sequel::DatabaseError) do
        database.read { |connection| connection.get(Sequel.lit('"not_a_column"')) }
      end
    end
  end

  def test_database_owner_is_reused_only_inside_the_current_process
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      first = Hive::RuntimeControlPlane.database(path: path)
      second = Hive::RuntimeControlPlane.database(path: path)

      assert_same first, second
      assert_equal Process.pid, first.owner_pid

      alternate = Hive::RuntimeControlPlane.database(path: File.join(root, "other.sqlite3"))
      refute_same first, alternate
      assert first.disconnected?
    end
  end

  def test_old_new_missing_duplicate_and_partial_migrations_fail_closed
    with_database do |database, path|
      set_schema_version(path, 0)
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :older_schema, error.code
      assert_match(/hive migrate --all/, error.message)

      set_schema_version(path, Hive::RuntimeControlPlane::SCHEMA_VERSION + 1)
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :newer_schema, error.code
    end

    with_database do |database, path|
      raw_sqlite(path) { |raw| raw.execute("DROP TABLE provider_audit") }
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :partial_schema, error.code
    end

    with_tmp_dir do |root|
      migrations = File.join(root, "migrations")
      FileUtils.mkdir_p(migrations)
      File.write(File.join(migrations, "002_gap.rb"), "Sequel.migration { up {} }\n")
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "missing.sqlite3"), migrations_dir: migrations
      )
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal :migration_set_invalid, error.code
      refute_path_exists database.path
    end

    with_tmp_dir do |root|
      migrations = File.join(root, "migrations")
      FileUtils.mkdir_p(migrations)
      File.write(File.join(migrations, "001_first.rb"), "Sequel.migration { up {} }\n")
      File.write(File.join(migrations, "001_duplicate.rb"), "Sequel.migration { up {} }\n")
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "duplicate.sqlite3"), migrations_dir: migrations
      )
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal :migration_set_invalid, error.code
      refute_path_exists database.path
    end
  end

  def test_unsupported_sqlite_or_missing_required_feature_fails_before_domain_query
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(
        path: path, sqlite_version: "3.34.9"
      )

      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.migrate! }
      assert_equal :sqlite_version_unsupported, error.code
      refute_path_exists path
    end

    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(
        path: path, feature_probe: ->(_connection) { false }
      )

      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.migrate! }
      assert_equal :sqlite_feature_missing, error.code
      refute_path_exists path
    end
  end

  def test_unrelated_and_corrupt_sqlite_files_have_typed_diagnostics
    with_tmp_dir do |root|
      path = File.join(root, "unrelated.sqlite3")
      raw_sqlite(path) { |raw| raw.execute("CREATE TABLE operator_data (value TEXT)") }
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      diagnosis = database.diagnostics
      assert_equal :unrelated_database, diagnosis.status
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :application_id_mismatch, error.code
    end

    with_tmp_dir do |root|
      path = File.join(root, "corrupt.sqlite3")
      File.binwrite(path, "this is not sqlite")
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      diagnosis = database.diagnostics
      assert_equal :corrupt, diagnosis.status
      assert_kind_of Hive::RuntimeControlPlane::IntegrityError, diagnosis.error
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
    end
  end

  def test_transaction_rolls_back_and_disconnect_is_idempotent
    with_database do |database|
      assert_raises(RuntimeError) do
        database.transaction do |connection|
          connection[:task_counters].insert(
            installation_id: installation_id(database), namespace: "test", value: 1,
            updated_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
          )
          raise "rollback"
        end
      end

      assert_equal 0, database.read { |connection| connection[:task_counters].count }
      database.disconnect
      database.disconnect
      assert database.disconnected?
    end
  end

  private

  def with_database
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path)
      database.migrate!
      yield database, path
    ensure
      database&.disconnect
    end
  end

  def raw_sqlite(path)
    require "sqlite3"
    database = SQLite3::Database.new(path)
    yield database
  ensure
    database&.close
  end

  def set_schema_version(path, version)
    raw_sqlite(path) { |raw| raw.execute("UPDATE schema_info SET version = ?", version) }
  end

  def installation_id(database)
    database.read { |connection| connection[:installations].get(:installation_id) }
  end
end
