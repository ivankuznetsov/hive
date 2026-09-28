# frozen_string_literal: true

require "test_helper"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/runtime_control_plane/installation"
require "logger"
require "stringio"
require "digest"

class RuntimeControlPlaneCommandSchemaTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test",
    location: "https://example.invalid/hive-compat-0.0.0-test.gem",
    sha256: "a" * 64
  }.freeze
  COMPATIBILITY_BASELINE = "f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d".freeze

  def test_additive_install_preserves_base_schema_and_rows
    Dir.mktmpdir do |dir|
      path = File.join(dir, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
      database.transaction do |db|
        installation_id = db[:installations].get(:installation_id)
        db[:daemon_runtime].insert(
          installation_id: installation_id, observation_json: '{"sentinel":true}'
        )
      end
      before_schema = base_schema(database)
      before_rows = base_rows(database)
      sql = StringIO.new
      logger = Logger.new(sql)
      database.read { |db| db.loggers << logger }

      result = Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )

      assert_equal "installed", result.fetch("status")
      assert_equal before_schema, base_schema(database)
      assert_equal before_rows, base_rows(database)
      base_names = before_rows.keys.join("|")
      mutating = sql.string.lines.filter_map do |line|
        statement = line.split(" INFO -- : ", 2)[1]&.sub(/\A\([^)]*\)\s*/, "")
        statement if statement&.match?(/\A(?:ALTER|DROP|UPDATE|DELETE)\b/i) &&
          statement.match?(/\b(?:#{base_names})\b/i)
      end
      assert_empty mutating
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

  def test_extension_version_ledger_is_part_of_exact_schema_validation
    assert_equal Hive::RuntimeControlPlane::CommandSchema::VERSION,
                 Hive::RuntimeControlPlane::CommandMigrations::AddCommandReceipts002::VERSION
    %i[unknown empty].each do |condition|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "runtime.sqlite3")
        database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
        Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
          database: database, package_coordinates: TEST_PACKAGE
        )
        database.transaction do |db|
          condition == :unknown ? db[:command_schema_versions].update(version: 99) :
            db[:command_schema_versions].delete
        end

        refute database.read { |db| Hive::RuntimeControlPlane::CommandSchema.exact?(db) }
        refute Hive::RuntimeControlPlane::CommandSchema.installed?(database)
        database.disconnect
        database = nil
        assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
          Hive::RuntimeControlPlane::Database.new(path: path).open!
        end
      ensure
        database&.disconnect
      end
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

  def test_compatibility_proof_tracks_schema_patch_and_fail_closed_install_sequence
    root = File.expand_path("../../..", __dir__)
    proof = File.read(File.join(root, "docs/implementation/command-receipt-compatibility-proof.md"))
    guide = File.read(File.join(root, "docs/guides/current-format-migration.md"))
    patch = File.join(root, "docs/implementation/command-receipt-compatibility.patch")
    patch_source = File.read(patch)
    patch_sha256 = Digest::SHA256.file(patch).hexdigest
    schema_sha256 = Hive::RuntimeControlPlane::CommandSchema::EXPECTED_SCHEMA_SHA256

    [ proof, guide ].each do |document|
      assert_includes document, COMPATIBILITY_BASELINE
      assert_includes document, "schema v#{Hive::RuntimeControlPlane::SCHEMA_VERSION}"
      assert_includes document, schema_sha256
      assert_includes document, patch_sha256
      assert_match(/ea14234d40d7efc995164ed9590ce7817a04d9ce2a40350577c3d852dea71c34/, document)
      assert_match(/sha256sum --check --strict &&\s*gem install/m, document)
    end
    refute_includes proof, "docs/artifacts/"
    refute_includes guide, "docs/artifacts/"

    object_block = patch_source.match(
      /^\+    COMMAND_RECEIPT_OBJECT_NAMES = %w\[\n(?<rows>.*?)^\+    \]\.freeze$/m
    )
    refute_nil object_block, "compatibility patch must carry a closed extension inventory"
    patched_objects = object_block[:rows].lines.filter_map do |line|
      line[/^\+      ([a-z][a-z0-9_]*)\s*$/, 1]
    end
    assert_equal Hive::RuntimeControlPlane::CommandSchema::OBJECT_NAMES.sort,
                 patched_objects.sort
    assert_includes patch_source,
                    %(EXPECTED_SCHEMA_SHA256 = "#{Hive::RuntimeControlPlane::EXPECTED_SCHEMA_SHA256}")
  end

  def test_install_rejects_partial_and_mismatched_extension_shapes
    diagnosis = Object.new
    diagnosis.define_singleton_method(:ok?) { true }
    partial = Object.new
    partial.define_singleton_method(:diagnostics) { diagnosis }
    partial.define_singleton_method(:read) { |&block| block.call(Object.new) }
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::CommandSchema, :installed?, ->(*) { false }
    ) do
      with_replaced_singleton_method(
        Hive::RuntimeControlPlane::CommandSchema, :absent?, ->(*) { false }
      ) do
        error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
          Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
            database: partial, package_coordinates: TEST_PACKAGE
          )
        end
        assert_equal :partial_command_schema, error.code
      end
    end

    Dir.mktmpdir do |dir|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(dir, "runtime.sqlite3")
      ).migrate!
      with_replaced_singleton_method(
        Hive::RuntimeControlPlane::CommandSchema, :exact?, ->(*) { false }
      ) do
        error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
          Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
            database: database, package_coordinates: TEST_PACKAGE
          )
        end
        assert_equal :command_schema_mismatch, error.code
      end
      assert database.read { |connection| Hive::RuntimeControlPlane::CommandSchema.absent?(connection) }
    ensure
      database&.disconnect
    end
  end

  private

    def base_schema(database)
      database.read do |db|
      db[:sqlite_master].where(type: %w[table index trigger view])
        .exclude(Sequel.like(:name, "sqlite_%"))
        .exclude(name: Hive::RuntimeControlPlane::CommandSchema::OBJECT_NAMES)
        .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
      end
    end

    def base_rows(database)
      database.read do |db|
        db[:sqlite_master].where(type: "table")
          .exclude(Sequel.like(:name, "sqlite_%"))
          .exclude(name: Hive::RuntimeControlPlane::CommandSchema::TABLE_NAMES)
          .order(:name).select_map(:name).to_h do |name|
            [ name, db[name.to_sym].all.map { |row| row.sort.to_h } ]
          end
      end
    end
end
