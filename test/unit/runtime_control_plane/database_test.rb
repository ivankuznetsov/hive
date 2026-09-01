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

  def test_migration_creates_owner_private_database_and_sidecars_under_permissive_umask
    with_tmp_dir do |root|
      path = File.join(root, "state", "runtime.sqlite3")
      previous = File.umask(0o022)
      database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
      database.transaction do |connection|
        connection[:task_counters].insert(
          installation_id: installation_id(database), namespace: "mode-proof", value: 1,
          updated_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
        )
      end

      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      [ path, "#{path}-wal", "#{path}-shm" ].each do |candidate|
        next unless File.exist?(candidate)
        assert_equal 0o600, File.lstat(candidate).mode & 0o777, candidate
      end
    ensure
      File.umask(previous) if previous
      database&.disconnect
    end
  end

  def test_unsafe_database_custody_fails_closed_before_sqlite_open
    with_database do |database, path|
      database.disconnect
      File.chmod(0o644, path)

      diagnosis = database.diagnostics

      assert_equal :corrupt, diagnosis.status
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :database_custody_invalid, error.code
    end

    with_database do |database, path|
      database.disconnect
      linked = "#{path}.linked"
      File.link(path, linked)

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :database_custody_invalid, error.code
    ensure
      FileUtils.rm_f(linked) if linked
    end
  end

  def test_exact_schema_rejects_column_constraint_and_unexpected_index_drift
    with_database do |database, path|
      database.disconnect
      raw_sqlite(path) do |raw|
        raw.execute("ALTER TABLE daemon_runtime RENAME COLUMN observation_json TO broken_json")
      end

      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :partial_schema, error.code
    end

    with_database do |database, path|
      database.disconnect
      raw_sqlite(path) { |raw| raw.execute("CREATE INDEX unexpected_runtime_idx ON daemon_runtime(daemon_kind)") }

      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :partial_schema, error.code
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

  def test_non_revalidating_open_reuses_validation_until_the_connection_is_lost
    with_database do |database|
      capability_checks = 0
      diagnoses = 0
      verify_capabilities = database.method(:verify_runtime_capabilities!)
      diagnose = database.method(:diagnostics_uncoordinated)
      database.define_singleton_method(:verify_runtime_capabilities!) do
        capability_checks += 1
        verify_capabilities.call
      end
      database.define_singleton_method(:diagnostics_uncoordinated) do
        diagnoses += 1
        diagnose.call
      end

      assert_same database, database.open!(revalidate: false)
      assert_same database, database.open!(revalidate: false)
      assert_equal 0, capability_checks
      assert_equal 0, diagnoses

      database.open!
      assert_equal 1, capability_checks
      assert_equal 1, diagnoses

      database.disconnect
      database.open!(revalidate: false)
      assert_equal 2, capability_checks
      assert_equal 2, diagnoses
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

  def test_migration_and_feature_probe_failures_are_typed
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      migrator = Object.new
      migrator.define_singleton_method(:run) { raise Sequel::DatabaseError, "migration failed" }
      replacement = ->(*) { migrator }
      error = with_replaced_singleton_method(Sequel::IntegerMigrator, :new, replacement) do
        assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.migrate! }
      end
      assert_equal :migration_failed, error.code
      assert database.disconnected?
    end

    with_tmp_dir do |root|
      invalid = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "invalid.sqlite3"), sqlite_version: "not-a-version"
      )
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { invalid.migrate! }
      assert_equal :sqlite_version_unsupported, error.code

      broken = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "broken.sqlite3"),
        feature_probe: ->(*) { raise Sequel::DatabaseError, "probe failed" }
      )
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { broken.migrate! }
      assert_equal :sqlite_feature_missing, error.code
    end
  end

  def test_diagnostics_classify_missing_schema_and_failed_integrity
    with_tmp_dir do |root|
      path = File.join(root, "missing-schema.sqlite3")
      raw_sqlite(path) do |raw|
        raw.execute("PRAGMA application_id = #{Hive::RuntimeControlPlane::APPLICATION_ID}")
        raw.execute("CREATE TABLE placeholder (id INTEGER)")
      end
      assert_equal :missing_schema,
                   Hive::RuntimeControlPlane::Database.new(path: path).diagnostics.status
    end

    with_database do |database|
      original = database.method(:pragma_rows)
      database.define_singleton_method(:pragma_rows) do |connection, name|
        name == "quick_check" ? [ "bad" ] : original.call(connection, name)
      end
      diagnosis = database.diagnostics
      assert_equal :corrupt, diagnosis.status
      assert_equal :integrity_check_failed, diagnosis.error.code
    end
  end

  def test_wal_migration_set_and_schema_helpers_fail_closed
    with_database do |database|
      database.disconnect
      original = database.method(:pragma_rows)
      database.define_singleton_method(:pragma_rows) do |connection, name|
        name == "journal_mode = WAL" ? [ "delete" ] : original.call(connection, name)
      end
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :wal_mode_unavailable, error.code
    end

    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "runtime.sqlite3"), migrations_dir: File.join(root, "missing")
      )
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal :migration_set_invalid, error.code
    end

    with_database do |database|
      fake = Object.new
      fake.define_singleton_method(:[]) { |_| raise Sequel::DatabaseError, "schema unreadable" }
      refute database.send(:exact_schema?, fake)

      dataset = Struct.new(:value) { def get(*) = value }.new("bad")
      schema = Object.new
      schema.define_singleton_method(:table_exists?) { |_| true }
      schema.define_singleton_method(:[]) { |_| dataset }
      assert_nil database.send(:schema_version_for, schema)
    end
  end

  def test_storage_parent_and_custody_io_fail_closed
    with_tmp_dir do |root|
      real = File.join(root, "real")
      link = File.join(root, "linked")
      FileUtils.mkdir_p(real)
      File.symlink(real, link)
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(link, "runtime.sqlite3"))
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.migrate! }
      assert_equal :database_custody_invalid, error.code
    end

    with_tmp_dir do |root|
      parent = File.join(root, "not-directory")
      File.binwrite(parent, "file")
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(parent, "runtime.sqlite3"))
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:prepare_storage!)
      end
      assert_equal :database_custody_invalid, error.code
    end

    with_database do |database, path|
      database.disconnect
      FileUtils.remove_entry(File.dirname(path))
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:validate_database_custody!)
      end
      assert_equal :database_custody_invalid, error.code
    end
  end

  def test_diagnostics_reraises_typed_internal_errors
    with_database do |database|
      database.define_singleton_method(:inspect_database) do |&block|
        fake = Object.new
        block.call(fake)
      end
      database.define_singleton_method(:integer_pragma) do |*, **|
        raise Hive::RuntimeControlPlane::IntegrityError.new("typed", code: :database_corrupt)
      end

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.diagnostics }
      assert_equal :database_corrupt, error.code
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
    File.chmod(0o600, path) if File.file?(path)
  end

  def set_schema_version(path, version)
    raw_sqlite(path) { |raw| raw.execute("UPDATE schema_info SET version = ?", version) }
  end

  def installation_id(database)
    database.read { |connection| connection[:installations].get(:installation_id) }
  end
end
