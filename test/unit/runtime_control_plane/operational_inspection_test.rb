require "test_helper"
require "hive/runtime_control_plane/operational_inspection"

class RuntimeControlPlaneOperationalInspectionTest < Minitest::Test
  include HiveTestHelper

  FakeDatabase = Struct.new(:path, :confirmed) do
    def confirmed_read_only_storage? = confirmed
  end

  def teardown
    Hive::RuntimeControlPlane::OperationalInspection.clear!
    super
  end

  def test_activation_requires_an_eligible_route_typed_read_only_failure_and_confirmed_mount
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      database = FakeDatabase.new(path, true)
      failure = Hive::RuntimeControlPlane::Unavailable.new(
        "Hive state is mounted read-only",
        code: :state_storage_read_only,
        action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
      )

      assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: failure, argv: %w[status --operational --json], state_home: root,
        database: database
      )
      assert Hive::RuntimeControlPlane::OperationalInspection.active?
      assert Hive::RuntimeControlPlane::OperationalInspection.active_for?(path)
      refute Hive::RuntimeControlPlane::OperationalInspection.active_for?(
        File.join(root, "other.sqlite3")
      )

      Hive::RuntimeControlPlane::OperationalInspection.clear!
      refute Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: failure, argv: %w[status --json], state_home: root,
        database: database
      )
      refute Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: Hive::RuntimeControlPlane::Unavailable.new(
          "busy", code: :database_busy, action: "retry"
        ),
        argv: %w[status --operational --json], state_home: root,
        database: database
      )
      refute Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: failure, argv: %w[status --operational --json], state_home: root,
        database: FakeDatabase.new(path, false)
      )
    end
  end

  def test_inherited_launch_reservation_never_activates_inspection
    with_tmp_dir do |root|
      error = Hive::RuntimeControlPlane::Unavailable.new(
        "read only", code: :state_storage_read_only,
        action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
      )

      refute Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: error, argv: %w[status --operational], state_home: root,
        inherited_reservation: true,
        database: FakeDatabase.new(Hive::Paths.runtime_control_plane_path(root), true)
      )
      refute Hive::RuntimeControlPlane::OperationalInspection.active?
    end
  end

  def test_clear_is_scoped_to_the_current_process
    with_tmp_dir do |root|
      error = Hive::RuntimeControlPlane::Unavailable.new(
        "read only", code: :state_storage_read_only,
        action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
      )
      database = FakeDatabase.new(Hive::Paths.runtime_control_plane_path(root), true)
      assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: error, argv: %w[status --operational], state_home: root,
        database: database
      )

      context = Thread.current[Hive::RuntimeControlPlane::OperationalInspection::THREAD_KEY]
      Thread.current[Hive::RuntimeControlPlane::OperationalInspection::THREAD_KEY] =
        context.merge(owner_pid: Process.pid + 1)
      refute Hive::RuntimeControlPlane::OperationalInspection.active?
      refute Hive::RuntimeControlPlane::OperationalInspection.active_for?(database.path)
    end
  end

  def test_active_context_routes_reads_and_open_validation_through_operational_inspection
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      activation_database = FakeDatabase.new(path, true)
      error = Hive::RuntimeControlPlane::Unavailable.new(
        "read only", code: :state_storage_read_only,
        action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
      )
      assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: error, argv: %w[status --operational], state_home: root,
        database: activation_database
      )

      database = Hive::RuntimeControlPlane::Database.new(path: path)
      calls = []
      database.define_singleton_method(:operational_read) do |**_options, &block|
        calls << :inspect
        block.call(:inspection_connection)
      end

      assert_same database, database.open!
      value = database.read do |connection|
        assert_equal :inspection_connection, connection
        :value
      end
      assert_equal :value, value
      assert_equal %i[inspect inspect], calls

      write_error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        database.transaction { flunk "inspection context must reject transactions" }
      end
      assert_equal :state_storage_read_only, write_error.code
      assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, write_error.action
    end
  end
end
