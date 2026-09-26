require "test_helper"
require "hive/runtime_control_plane/command_registration"
require "hive/runtime_control_plane/lifecycle_repository"

class RuntimeControlPlaneCommandRegistrationTest < Minitest::Test
  include HiveTestHelper

  def test_timeout_option_values_do_not_hide_lifecycle_subcommands
    assert Hive::RuntimeControlPlane::CommandRegistration.exempt?(
      %w[daemon --timeout 30 quiesce]
    )
    assert Hive::RuntimeControlPlane::CommandRegistration.exempt?(
      %w[daemon --timeout=30 resume]
    )
  end

  def test_workflow_observation_routes_are_exempt_from_registration
    [
      %w[init --new-workflow editorial --preview --json],
      %w[init --new-workflow workflow --preview=true --json],
      %w[workflow validate coding --json],
      %w[workflow --json validate coding]
    ].each do |argv|
      assert Hive::RuntimeControlPlane::CommandRegistration.exempt?(argv), argv.inspect
    end
    refute Hive::RuntimeControlPlane::CommandRegistration.exempt?(
      %w[new project workflow validate]
    )
  end

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

  def test_parent_registers_gated_hive_child_and_child_adopts_the_same_row
    with_runtime do |root, database|
      registration = Hive::RuntimeControlPlane::CommandRegistration.start!(
        argv: %w[new task], state_home: root
      )
      bin = File.expand_path("../../../bin/hive", __dir__)
      log = Tempfile.new("hive-registration-child")
      pid = with_env("HIVE_HOME" => root) do
        Hive::RuntimeControlPlane::CommandRegistration.spawn_registered_hive!(
          RbConfig.ruby, "-I#{File.expand_path('../../../lib', __dir__)}", bin, "version",
          role: "version-probe", out: log, err: log
        )
      end
      _, status = Process.wait2(pid)
      log.rewind
      log_output = log.read
      assert status.success?, log_output

      rows = database.read { |db| db[:owned_processes].order(:created_at).all }
      assert_equal 2, rows.size, "child must adopt the parent-created row, not add a duplicate"
      child = rows.find { |row| row.fetch(:reservation_id) != registration.reservation_id }
      assert_equal "version-probe", child.fetch(:role)
      assert_equal pid, child.fetch(:pid)
      assert_equal "stopped", child.fetch(:state),
                   "#{log_output}\nparent=#{registration.reservation_id}\nrows=#{rows.inspect}"
      reservation_state = database.read do |db|
        db[:launch_reservations].where(reservation_id: child.fetch(:reservation_id)).get(:state)
      end
      assert_equal "released", reservation_state
    ensure
      log&.close!
    end
  end

  def test_parent_exit_does_not_release_a_live_background_child_registration
    with_runtime do |root, database|
      registration = Hive::RuntimeControlPlane::CommandRegistration.start!(
        argv: %w[new task], state_home: root
      )
      script = <<~'RUBY'
        gate = IO.for_fd(Integer(ENV.fetch("HIVE_LAUNCH_GATE_FD"), 10), "r")
        exit 75 unless gate.read(1) == "1"
        sleep 30
      RUBY
      pid = registration.spawn_registered_hive!(
        RbConfig.ruby, "-e", script, role: "background-probe",
        out: File::NULL, err: File::NULL
      )

      assert registration.finish!
      rows = database.read { |db| db[:owned_processes].all }
      parent = rows.find { |row| row.fetch(:reservation_id) == registration.reservation_id }
      child = rows.find { |row| row.fetch(:pid) == pid }
      assert_equal "stopped", parent.fetch(:state)
      assert_equal "running", child.fetch(:state),
                   "the child owns a separate durable row after its parent exits"
    ensure
      Process.kill("TERM", pid) if pid
      Process.wait(pid) if pid
    end
  end

  def test_handoff_fails_closed_if_runtime_storage_disappears
    with_tmp_dir do |root|
      with_env(
        Hive::RuntimeControlPlane::CommandRegistration::CHILD_RESERVATION_ENV => "missing"
      ) do
        error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
          Hive::RuntimeControlPlane::CommandRegistration.start!(
            argv: %w[generate-name task], state_home: root
          )
        end
        assert_equal :launch_handoff_unavailable, error.code
      end
    end
  end

  def test_class_spawn_helper_preserves_direct_in_process_callers_without_registration
    calls = []
    spawner = lambda do |*argv, **options|
      calls << [ argv, options ]
      12_345
    end

    pid = Hive::RuntimeControlPlane::CommandRegistration.spawn_registered_hive!(
      "hive", "generate-name", "task", role: "generate-name", spawner: spawner,
      pgroup: true
    )

    assert_equal 12_345, pid
    assert_equal [ [ %w[hive generate-name task], { pgroup: true } ] ], calls
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
