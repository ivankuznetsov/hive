require "test_helper"
require "hive/daemon/checkpoint_maintenance"
require "hive/runtime_control_plane/lifecycle_repository"

class HiveDaemonCheckpointMaintenanceTest < Minitest::Test
  include HiveTestHelper

  class FakeDatabase
    attr_accessor :wal_bytes, :failure, :callback
    attr_reader :calls

    def initialize
      @wal_bytes = 100
      @calls = []
    end

    def checkpoint_role = :daemon_backed
    def path = Hive::Paths.runtime_control_plane_path
    def disconnect = @calls << :disconnect

    def passive_checkpoint!(timeout_sec:)
      @calls << timeout_sec
      callback&.call
      raise failure if failure

      { complete: false, busy: 0, log_frames: 5000, checkpointed_frames: 10,
        remaining_frames: 4990, page_size: 4096, wal_bytes: wal_bytes,
        duration_sec: 0.001 }
    end
  end

  def test_normal_and_high_water_cadence_is_monotonic_and_one_pass_per_tick
    now = 0.0
    database = FakeDatabase.new
    reports = []
    maintenance = Hive::Daemon::CheckpointMaintenance.new(
      database: database, logger: logger(reports), monotonic: -> { now }
    )
    first = maintenance.sweep
    assert first.fetch(:deferred)
    assert_equal 30.0, first.fetch(:cadence_sec)
    assert_equal 4073, first.fetch(:high_water_frames)
    now = 29.999
    assert_nil maintenance.sweep
    now = 30.0
    assert maintenance.sweep
    database.wal_bytes = 16 * 1024 * 1024
    now = 30.999
    assert_nil maintenance.sweep
    now = 31.0
    high = maintenance.sweep
    assert high.fetch(:high_water)
    assert_equal 1.0, high.fetch(:cadence_sec)
    3.times { assert_nil maintenance.sweep }
    database.wal_bytes = 0
    now = 60.99
    assert_nil maintenance.sweep
    now = 61.0
    assert maintenance.sweep
    assert_equal [ 0.25 ] * 4, database.calls
    assert_equal 4, reports.size
    assert reports.all? { |event, _| event == :runtime_checkpoint_maintenance }
  end

  def test_errors_defer_and_consume_cadence_and_logging_cannot_break_the_tick
    now = 0.0
    database = FakeDatabase.new
    database.failure = IOError.new("checkpoint unavailable")
    reports = []
    maintenance = Hive::Daemon::CheckpointMaintenance.new(
      database: database, logger: logger(reports), monotonic: -> { now }
    )
    result = maintenance.sweep
    assert result.fetch(:deferred)
    assert_equal "IOError", result.fetch(:error_class)
    now = 1
    assert_nil maintenance.sweep
    now = 30
    assert maintenance.sweep
    assert_equal 2, database.calls.size
    broken_logger = Object.new
    broken_logger.define_singleton_method(:event) { |*| raise IOError, "logging failed" }
    maintenance = Hive::Daemon::CheckpointMaintenance.new(database: database, logger: broken_logger)
    assert maintenance.sweep.fetch(:deferred)
  end

  def test_owned_connection_rejects_inherited_and_overlapping_passes
    database = FakeDatabase.new
    reports = []
    maintenance = Hive::Daemon::CheckpointMaintenance.new(database: database, logger: logger(reports))
    database.callback = -> { assert_nil maintenance.sweep }
    assert maintenance.sweep
    assert_equal 1, database.calls.size
    maintenance.instance_variable_set(:@owner_pid, -1)
    assert_nil maintenance.sweep
    assert_nil maintenance.close
    assert_equal 1, database.calls.size
    assert_raises(ArgumentError) do
      Hive::Daemon::CheckpointMaintenance.new(database: database, logger: logger(reports), high_water_bytes: 0)
    end
  end

  def test_actual_maintenance_reports_pinned_growth_and_stops_at_lifecycle_fence
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      writer = Hive::RuntimeControlPlane::Database.new(path: path, checkpoint_role: :daemon_backed).migrate!
      reports = []
      now = 0.0
      maintenance = Hive::Daemon::CheckpointMaintenance.new(
        path: path, logger: logger(reports), high_water_bytes: 1024, monotonic: -> { now }
      )
      writer.checkpoint!
      reader = SQLite3::Database.new(path)
      reader.execute("BEGIN")
      reader.execute("SELECT * FROM installations")
      writer.transaction { |sql| sql[:installations].update(activation_epoch: 1) }
      deferred = maintenance.sweep
      assert deferred.fetch(:deferred)
      assert deferred.fetch(:high_water)
      assert_operator deferred.fetch(:remaining_frames), :>, 0
      assert_equal :daemon_backed, maintenance.database.checkpoint_role
      writer.transaction { |sql| sql[:installations].update(activation_epoch: 2) }
      reader.execute("ROLLBACK")
      now = 1.0
      assert maintenance.sweep.fetch(:complete)
      writer.transaction { |sql| sql[:runtime_lifecycle].update(phase: "quiescing") }
      now = 2.0
      blocked = maintenance.sweep
      assert blocked.fetch(:deferred)
      assert_equal "Hive::RuntimeControlPlane::AdmissionClosed", blocked.fetch(:error_class)
      writer.with_exclusive_writer(role: :migrator) do
        now = 3.0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        fenced = maintenance.sweep
        assert_equal "Hive::RuntimeControlPlane::FileFence::Busy", fenced.fetch(:error_class)
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
      end
      Hive::RuntimeControlPlane::OperationLock.new(state_home: root).synchronize do
        now = 4.0
        fenced = maintenance.sweep
        assert_equal "Hive::RuntimeControlPlane::FileFence::Busy", fenced.fetch(:error_class)
      end
    ensure
      reader&.close
      maintenance&.close
      writer&.disconnect
    end
  end

  private

  def logger(reports)
    Object.new.tap do |instance|
      instance.define_singleton_method(:event) { |name, **attributes| reports << [ name, attributes ] }
    end
  end
end
