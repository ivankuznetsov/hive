require "test_helper"
require "hive/runtime_control_plane/command_registration"
require "hive/runtime_control_plane/lifecycle_repository"

class RuntimeControlPlaneCommandRegistrationTest < Minitest::Test
  include HiveTestHelper

  def test_non_control_command_registers_until_finished
    with_runtime do |root, database|
      registration = Hive::RuntimeControlPlane::CommandRegistration.start!(
        argv: %w[new task], state_home: root
      )

      row = database.read { |db| db[:owned_processes].first }
      assert_equal "running", row.fetch(:state)
      assert_equal "direct_cli", row.fetch(:origin)
      assert_equal "new", row.fetch(:role)
      assert_equal Process.pid, row.fetch(:pid)

      registration.finish!
      assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
    end
  end

  def test_control_and_read_only_maintenance_commands_never_register
    with_runtime do |root, database|
      [
        %w[daemon status --json], %w[daemon quiesce], %w[daemon resume],
        %w[runtime status], %w[doctor], %w[setup], %w[--version]
      ].each do |argv|
        assert_nil Hive::RuntimeControlPlane::CommandRegistration.start!(
          argv: argv, state_home: root
        )
      end

      assert_equal 0, database.read { |db| db[:owned_processes].count }
    end
  end

  def test_command_start_is_denied_after_admission_closes
    with_runtime do |root, database|
      Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).begin_quiesce!(
        deadline_monotonic: 20, boot_id: "boot", shutdown_grace_sec: 5
      )

      assert_raises(Hive::RuntimeControlPlane::AdmissionClosed) do
        Hive::RuntimeControlPlane::CommandRegistration.start!(
          argv: %w[new task], state_home: root
        )
      end
      %w[start reload].each do |action|
        assert_raises(Hive::RuntimeControlPlane::AdmissionClosed) do
          Hive::RuntimeControlPlane::CommandRegistration.start!(
            argv: [ "daemon", action ], state_home: root
          )
        end
      end
      assert_equal 0, database.read { |db| db[:owned_processes].count }
    end
  end

  def test_finish_uses_the_single_cleanup_window_after_closure
    with_runtime do |root, database|
      registration = Hive::RuntimeControlPlane::CommandRegistration.start!(
        argv: %w[new task], state_home: root
      )
      Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).begin_quiesce!(
        deadline_monotonic: 20, boot_id: "boot", shutdown_grace_sec: 5
      )

      assert registration.finish!
      assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
      assert_equal 1, database.read { |db| db[:quiescence_cleanup_writes].count }
    end
  end

  private

  def with_runtime
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      yield root, database
    ensure
      Hive::RuntimeControlPlane::CommandRegistration.reset!
      database&.disconnect
    end
  end
end
