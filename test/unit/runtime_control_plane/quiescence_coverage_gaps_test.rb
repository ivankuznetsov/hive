require "test_helper"
require "hive/runtime_control_plane/activation_gate"
require "hive/runtime_control_plane/boot_identity"
require "hive/runtime_control_plane/command_registration"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/process_registry"
require "hive/runtime_control_plane/quiescence_upgrade"

class RuntimeControlPlaneQuiescenceCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  FakeDataset = Struct.new(:row, :updated) do
    def first = row
    def get(column) = row && row[column]
    def insert(value) = self.row = value
    def delete = true
    def update(*) = updated.nil? ? 1 : updated
    def multi_insert(*) = true
  end

  class FakeUpgradeConnection
    attr_accessor :violations, :foreign_keys, :fingerprint

    def initialize
      @violations = []
      @foreign_keys = 1
      @fingerprint = Hive::RuntimeControlPlane::EXPECTED_SCHEMA_SHA256
      @datasets = Hash.new { |hash, key| hash[key] = FakeDataset.new }
    end

    def run(*) = true
    def tables = [ :schema_info ]
    def table_exists?(_table) = false
    def transaction(*) = yield
    def fetch(statement)
      values = statement.include?("foreign_key_check") ? violations : []
      Struct.new(:values) { def all = values }.new(values)
    end
    def [](table) = @datasets[table]
    def disconnect = true
  end

  def test_activation_gate_skips_inline_timeout_values
    argv = %w[daemon --timeout=2 resume]
    assert_equal "resume", Hive::RuntimeControlPlane::ActivationGate.subcommand_after(
      argv, "daemon", value_options: %w[--timeout]
    )
  end

  def test_boot_identity_falls_back_to_init_identity_and_fails_closed_on_io
    file_probe = ->(path) { path != "/proc/sys/kernel/random/boot_id" && File.file?(path) }
    with_replaced_singleton_method(File, :file?, file_probe) do
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "start-1" }) do
        assert_match(/\A[0-9a-f]{64}\z/, Hive::RuntimeControlPlane::BootIdentity.current)
      end
    end

    with_replaced_singleton_method(File, :file?, ->(*) { true }) do
      with_replaced_singleton_method(File, :read, ->(*) { raise IOError, "unreadable" }) do
        assert_nil Hive::RuntimeControlPlane::BootIdentity.current
      end
    end
  end

  def test_command_registration_rebinds_and_disconnect_failure_is_bounded
    calls = []
    registry = Object.new
    registry.define_singleton_method(:rebind!) { |id, pid:| calls << [ id, pid ] }
    database = Object.new
    database.define_singleton_method(:disconnect) { raise Sequel::Error, "closed" }
    registration = Hive::RuntimeControlPlane::CommandRegistration.new(
      database: database, registry: registry, reservation_id: "reservation-1"
    )
    Hive::RuntimeControlPlane::CommandRegistration.instance_variable_set(:@current, registration)

    assert_same registration, Hive::RuntimeControlPlane::CommandRegistration.rebind_after_daemonize!
    assert_equal [ [ "reservation-1", Process.pid ] ], calls
    refute registration.disconnect
  ensure
    Hive::RuntimeControlPlane::CommandRegistration.instance_variable_set(:@current, nil)
  end

  def test_database_writer_authority_and_status_error_contracts
    with_database do |database|
      assert_equal 1, database.migrator_transaction { |db| db[:installations].count }
      assert_raises(ArgumentError) { database.with_exclusive_writer(role: :worker) { } }
      assert_raises(ArgumentError) do
        database.upgrade_quiescence!(
          authority: Object.new, expected_schema_version: 1,
          expected_fingerprint: "old", preserve_lifecycle: false
        )
      end

      database.define_singleton_method(:quiescence_upgrade_source) do
        raise Hive::RuntimeControlPlane::MigrationRequired.new("typed", code: :typed)
      end
      assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        database.upgrade_quiescence!(
          authority: database.send(:authority_for, :migrator), expected_schema_version: 1,
          expected_fingerprint: "old", preserve_lifecycle: false
        )
      end

      database.define_singleton_method(:diagnostics_uncoordinated) { raise IOError, "broken" }
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.quiescence_status_snapshot
      end
      assert_equal :database_corrupt, error.code
    end
  end

  def test_database_upgrade_wraps_untyped_storage_failures
    with_database do |database|
      source = {
        application_id: Hive::RuntimeControlPlane::APPLICATION_ID,
        schema_version: 1, schema_fingerprint: "old", lifecycle: nil
      }
      database.define_singleton_method(:quiescence_upgrade_source) { source }
      error = with_replaced_singleton_method(
        database, :disconnect, -> { raise IOError, "cannot close" }
      ) do
        assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
          database.upgrade_quiescence!(
            authority: database.send(:authority_for, :migrator), expected_schema_version: 1,
            expected_fingerprint: "old", preserve_lifecycle: false
          )
        end
      end
      assert_equal :quiescence_upgrade_failed, error.code
    end
  end

  def test_database_status_helpers_fail_closed_on_query_errors
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/not-opened.sqlite3")
    broken = Object.new
    broken.define_singleton_method(:table_exists?) { |_| raise Sequel::Error, "bad schema" }
    refute database.send(:table_has_columns?, broken, :attempts, :state)

    dataset = Object.new
    dataset.define_singleton_method(:first) { raise Sequel::Error, "bad row" }
    dataset.define_singleton_method(:where) { |**| self }
    dataset.define_singleton_method(:exclude) { |**| self }
    dataset.define_singleton_method(:all) { raise Sequel::Error, "bad rows" }
    broken.define_singleton_method(:table_exists?) { |_| true }
    broken.define_singleton_method(:schema) { |_| [ [ :state ] ] }
    broken.define_singleton_method(:[]) { |_| dataset }

    assert_nil database.send(:first_row, broken, :attempts)
    assert_empty database.send(:rows_with_states, broken, :attempts, %w[running])
    assert_empty database.send(:rows_except_state, broken, :attempts, "stopped")
  end

  def test_upgrade_copy_validates_foreign_keys_enforcement_and_schema
    source = FakeUpgradeConnection.new
    target = FakeUpgradeConnection.new
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/source.sqlite3")
    database.define_singleton_method(:integer_pragma) { |connection, _| connection.foreign_keys }
    database.define_singleton_method(:schema_fingerprint) { |connection| connection.fingerprint }

    target.violations = [ { table: "attempts" } ]
    error = with_fake_sequel_connections(source, target) do
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:copy_quiescence_source!, "/tmp/target.sqlite3", now: Time.now.utc,
                      preserve_lifecycle: false)
      end
    end
    assert_equal :quiescence_upgrade_foreign_key_failed, error.code

    target = FakeUpgradeConnection.new
    target.foreign_keys = 0
    error = with_fake_sequel_connections(source, target) do
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:copy_quiescence_source!, "/tmp/target.sqlite3", now: Time.now.utc,
                      preserve_lifecycle: false)
      end
    end
    assert_equal :quiescence_upgrade_foreign_keys_disabled, error.code

    target = FakeUpgradeConnection.new
    target.fingerprint = "wrong"
    error = with_fake_sequel_connections(source, target) do
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:copy_quiescence_source!, "/tmp/target.sqlite3", now: Time.now.utc,
                      preserve_lifecycle: false)
      end
    end
    assert_equal :quiescence_upgrade_schema_mismatch, error.code
  end

  def test_preserved_lifecycle_must_stay_closed_and_update_once
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/runtime.sqlite3")
    target = FakeUpgradeConnection.new
    error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
      database.send(:preserve_closed_lifecycle!, target, now: Time.now.utc)
    end
    assert_equal :quiescence_upgrade_requires_closed_lifecycle, error.code

    target[:runtime_lifecycle].row = {
      phase: "paused", installation_id: "install-1", revision: 1, mutation_sequence: 2
    }
    target[:runtime_lifecycle].updated = 0
    target[:runtime_lifecycle].define_singleton_method(:where) { |**| self }
    error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
      database.send(:preserve_closed_lifecycle!, target, now: Time.now.utc)
    end
    assert_equal :quiescence_upgrade_lifecycle_failed, error.code
  end

  def test_file_fence_waits_and_wraps_release_and_open_errors
    with_tmp_dir do |root|
      path = File.join(root, "fence")
      holder = Hive::RuntimeControlPlane::FileFence.new(path: path, timeout_sec: 0)
      holder.acquire_exclusive!
      sleeps = []
      contender = Hive::RuntimeControlPlane::FileFence.new(
        path: path, timeout_sec: 0.01, sleeper: ->(seconds) { sleeps << seconds; sleep(seconds) }
      )
      assert_raises(Hive::ConcurrentRunError) { contender.acquire_exclusive! }
      refute_empty sleeps

      broken = Object.new
      broken.define_singleton_method(:flock) { |_| raise IOError, "unlock failed" }
      fence = Hive::RuntimeControlPlane::FileFence.new(path: path, timeout_sec: 0)
      fence.instance_variable_set(:@handle, broken)
      assert_raises(Hive::ConfigError) { fence.release! }
    ensure
      holder&.release!
    end

    with_tmp_dir do |root|
      parent = File.join(root, "file")
      File.write(parent, "not a directory")
      fence = Hive::RuntimeControlPlane::FileFence.new(
        path: File.join(parent, "fence"), timeout_sec: 0
      )
      assert_raises(Hive::ConfigError) { fence.acquire_exclusive! }
    end
  end

  def test_lifecycle_admission_and_busy_phase_fail_closed
    with_database do |database|
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      assert database.read { |db| repository.ensure_admission_open_in!(db) }
      state = repository.begin_quiesce!(
        deadline_monotonic: 10, boot_id: "boot", shutdown_grace_sec: 1
      )
      error = assert_raises(Hive::RuntimeControlPlane::AdmissionClosed) do
        database.read { |db| repository.ensure_admission_open_in!(db) }
      end
      assert_equal state.generation, error.details.fetch(:generation)
      repository.begin_resume!(generation: state.generation)
      assert_raises(Hive::RuntimeControlPlane::StaleLifecycle) do
        repository.begin_quiesce!(
          deadline_monotonic: 10, boot_id: "boot", shutdown_grace_sec: 1
        )
      end
    end
  end

  def test_process_registry_rejects_missing_identities_and_supports_authorized_cleanup
    identity = Object.new
    identity.define_singleton_method(:capture) { |_| nil }
    with_registry(process_identity: identity) do |_database, registry, _root|
      assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        registry.register!("missing", pid: 1)
      end
      assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        registry.rebind!("missing", pid: 1)
      end
    end

    with_registry do |database, registry, _root|
      reservation = registry.reserve!(origin: "direct_cli", role: "status")
      registry.register!(reservation.id, pid: Process.pid)
      reservation.release_fence!
      database.with_exclusive_writer(role: :controller) do |authority|
        registry.mark_stopped_by_reservation!(reservation.id, authority: authority)
      end
      assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
    ensure
      reservation&.release_fence!
    end
  end

  def test_quiescence_capability_reports_unregistered_attempt_identity_and_storage_errors
    identity = Object.new
    identity.define_singleton_method(:status) { |_| :mismatched }
    identity.define_singleton_method(:capture) { |_| nil }
    custody = Hive::Attempts::ProcessCustody.unsupported("test")

    rows = {
      reservations: [], processes: [],
      attempts: [ { attempt_id: "attempt-1" } ]
    }
    inert_database = Struct.new(:path).new("/tmp/runtime.sqlite3")
    capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
      database: inert_database, process_identity: identity, custody: custody,
      legacy_inventory: -> { [] }
    )
    assert_equal "unregistered_attempt_root", capability.call(snapshot: rows).reason

    delegated = Object.new
    delegated.define_singleton_method(:available?) { true }
    delegated.define_singleton_method(:verifiable?) { |_| true }
    delegated.define_singleton_method(:mode) { "delegated_cgroup_v2" }
    rows = {
      reservations: [], attempts: [ { attempt_id: "attempt-1" } ], processes: [ {
        pid: 1, start_fingerprint: "start", session_id: 1, process_group_id: 1,
        attempt_id: "attempt-1", proven_child_safe: 0, origin: "attempt"
      } ]
    }
    capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
      database: inert_database, process_identity: identity, custody: delegated,
      legacy_inventory: -> { [] }
    )
    assert_equal "process_identity_unverifiable", capability.call(snapshot: rows).reason

    database = Object.new
    database.define_singleton_method(:path) { "/tmp/runtime.sqlite3" }
    database.define_singleton_method(:read) do
      raise Hive::RuntimeControlPlane::Unavailable.new("offline", code: :offline)
    end
    capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
      database: database, process_identity: identity, custody: custody,
      legacy_inventory: -> { [] }
    )
    assert_equal "offline", capability.call.reason
  end

  def test_legacy_inventory_records_unreadable_receipts_and_supervisor_identity
    with_tmp_dir do |root|
      File.write(File.join(root, ".daemon.pid"), "[invalid")
      File.write(File.join(root, ".bot.pid"), { "pid" => "bad" }.to_yaml)
      identity = Object.new
      identity.define_singleton_method(:capture) { |_| nil }
      identity.define_singleton_method(:status) { |_| :missing }
      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: Struct.new(:path).new(File.join(root, "runtime.sqlite3")),
        state_home: root, process_identity: identity,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      )
      with_env("HIVEBOX_SUPERVISOR_PID" => "123") do
        inventory = capability.send(:known_legacy_processes)
        assert_equal 3, inventory.length
        assert inventory.all? { |entry| entry.fetch("unknown_reason") }
      end
    end
  end

  def test_quiescence_upgrade_rejects_unsafe_proof_custody
    with_tmp_dir do |root|
      proof = Hive::Paths.runtime_quiescence_proof_path(root)
      target = File.join(root, "proof-target")
      File.write(target, "proof", perm: 0o600)
      File.symlink(target, proof)
      upgrade = Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
        state_home: root, ownership_verifier: -> { true }
      )

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        upgrade.send(:invalidate_proof!)
      end
      assert_equal :proof_custody_invalid, error.code
    end
  end

  private

  def with_fake_sequel_connections(source, target)
    connections = [ source, target ]
    with_replaced_singleton_method(Sequel, :connect, ->(**) { connections.shift }) { yield }
  end

  def with_database
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      yield database
    ensure
      database&.disconnect
    end
  end

  def with_registry(process_identity: Hive::Attempts::ProcessIdentity.new)
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root, process_identity: process_identity
      )
      yield database, registry, root
    ensure
      database&.disconnect
    end
  end
end
