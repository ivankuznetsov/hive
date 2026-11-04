require "tmpdir"
require "json"
require "hive/runtime_control_plane"
require "hive/daemon/checkpoint_maintenance"
require "hive/daemon/quiescence"
require_relative "runtime_database_contention_workload"

# Storage-policy qualification, separate from the fixed writer comparison.
# Pins a reader across repeated publications of the fixed comparison snapshot.
module RuntimeCheckpointWorkload
  def self.run(root:)
    path = Hive::Paths.runtime_control_plane_path(root)
    writer = Hive::RuntimeControlPlane::Database.new(path: path, checkpoint_role: :daemon_backed).migrate!
    reports = []
    logger = Object.new
    logger.define_singleton_method(:event) { |_name, **attributes| reports << attributes }
    now = 0.0
    maintenance = Hive::Daemon::CheckpointMaintenance.new(path: path, logger: logger, monotonic: -> { now })
    publisher = Hive::RuntimeControlPlane::OperationalRepository.new(database: writer)
    writer.checkpoint!
    reader = SQLite3::Database.new(path)
    reader.execute("BEGIN")
    reader.execute("SELECT * FROM installations")
    document = RuntimeDatabaseContentionWorkload.snapshot
    snapshot_bytes = Hive::RuntimeControlPlane::Codec.dump_json(document).bytesize
    writes = Array.new(72) do |index|
      document.fetch("tasks").each do |row|
        row["detail"] = (97 + index % 26).chr * RuntimeDatabaseContentionWorkload::MANIFEST.fetch(:row_padding_bytes)
      end
      raise "qualification enlarged fixed snapshot" unless
        Hive::RuntimeControlPlane::Codec.dump_json(document).bytesize == snapshot_bytes
      started = monotonic
      publisher.publish(document)
      elapsed = monotonic - started
      now = index / 5.0
      result = maintenance.sweep
      { duration_sec: elapsed, wal_bytes: writer.wal_bytes, maintenance: result }
    end
    peak = writes.map { |item| item.fetch(:wal_bytes) }.max
    raise "pinned-reader qualification failed to cross high water" unless peak > 16 * 1024 * 1024
    raise "pinned reader was not deferred" unless reports.last.fetch(:deferred)

    reader.execute("ROLLBACK")
    now += 1
    drain = maintenance.sweep
    raise "reader release did not permit progress" unless drain.fetch(:complete)

    full_duration = nil
    full = writer.method(:checkpoint!)
    writer.define_singleton_method(:checkpoint!) do |**options|
      started = RuntimeCheckpointWorkload.monotonic
      result = full.call(**options)
      full_duration = RuntimeCheckpointWorkload.monotonic - started
      result
    end
    started = monotonic
    pause = Hive::Daemon::Quiescence.new(state_home: root, database: writer).call
    pause_duration = monotonic - started
    raise "quiescence failed: #{pause.reason}" unless pause.paused && pause.checkpoint.fetch(:complete)

    started = monotonic
    writer.with_exclusive_writer(role: :migrator) { writer.send(:checkpoint_upgrade_source!) }
    truncate_duration = monotonic - started
    raise "upgrade checkpoint did not truncate WAL" unless writer.wal_bytes.zero?

    {
      manifest: {
        rows: document.fetch("tasks").size,
        row_padding_bytes: RuntimeDatabaseContentionWorkload::MANIFEST.fetch(:row_padding_bytes),
        snapshot_bytes: snapshot_bytes, publications: 72, pinned_reader: true,
        maintenance_clock: "injected monotonic, publication index / 5Hz",
        writer_count: 1, comparison_run: false
      },
      roles: { daemon_backed: 0, manual_default: 4096 }, peak_wal_bytes: peak,
      writes: writes, maintenance_reports: reports, released_reader_drain: drain,
      quiescence_duration_sec: pause_duration,
      quiescence_budget_sec: Hive::Daemon::Quiescence::DEFAULT_TIMEOUT_SEC,
      lifecycle_full_duration_sec: full_duration,
      lifecycle_checkpoint: pause.checkpoint,
      upgrade_truncate_duration_sec: truncate_duration,
      upgrade_sqlite_timeout_sec: Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS / 1000.0,
      upgrade_truncate_complete: true, after_truncate_wal_bytes: writer.wal_bytes
    }
  ensure
    reader&.close
    maintenance&.close
    writer&.disconnect
  end

  def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

if $PROGRAM_NAME == __FILE__
  Dir.mktmpdir("hive-checkpoint-qualification") do |root|
    puts JSON.pretty_generate(RuntimeCheckpointWorkload.run(root: root))
  end
end
