# frozen_string_literal: true

require "test_helper"
require "hive/runtime_control_plane/command_schema_installation"

class RuntimeControlPlaneCommandSchemaTest < Minitest::Test
  TEST_PACKAGE = {
    version: "0.0.0-test",
    location: "https://example.invalid/hive-compat-0.0.0-test.gem",
    sha256: "a" * 64
  }.freeze

  def test_additive_install_preserves_base_schema_and_rows
    Dir.mktmpdir do |dir|
      path = File.join(dir, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
      before_schema = base_schema(database)
      before_rows = database.read { |db| db[:installations].all }

      result = Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )

      assert_equal "installed", result.fetch("status")
      assert_equal before_schema, base_schema(database)
      assert_equal before_rows, database.read { |db| db[:installations].all }
      assert_equal :ok, database.diagnostics.status
      assert Hive::RuntimeControlPlane::CommandSchema.installed?(database)
    ensure
      database&.disconnect
    end
  end

  def test_install_is_idempotent_for_an_exact_extension
    Dir.mktmpdir do |dir|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(dir, "runtime.sqlite3")
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )

      result = Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )

      assert_equal "already_installed", result.fetch("status")
    ensure
      database&.disconnect
    end
  end

  def test_partial_or_unknown_extension_objects_fail_closed
    Dir.mktmpdir do |dir|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(dir, "runtime.sqlite3")
      ).migrate!
      database.transaction { |db| db.create_table(:command_receipts) { String :receipt_id } }
      database.disconnect

      assert_equal :partial_schema, database.diagnostics.status
    ensure
      database&.disconnect
    end
  end

  def test_missing_published_coordinates_refuse_before_fresh_base_bootstrap
    Dir.mktmpdir do |dir|
      error = assert_raises(Hive::ConfigError) do
        Hive::RuntimeControlPlane::Installation.setup(
          state_home: dir, install_command_receipts: true
        )
      end

      assert_includes error.message, "no published rollback package"
      assert_includes error.message, "without --install-command-receipts"
      refute File.exist?(Hive::Paths.runtime_control_plane_path(dir))
    end
  end

  private

  def base_schema(database)
    database.read do |db|
      db[:sqlite_master].where(type: %w[table index])
        .exclude(name: "schema_info").exclude(Sequel.like(:name, "sqlite_%"))
        .exclude(name: Hive::RuntimeControlPlane::CommandSchema::OBJECT_NAMES)
        .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
    end
  end
end
