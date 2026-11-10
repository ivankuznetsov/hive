require "tmpdir"
require "json"
require "hive/runtime_control_plane"

# Fixed-size comparison fixture. Child processes own their connections and
# measurements; no shared Ruby connection crosses fork.
module RuntimeDatabaseContentionWorkload
  MANIFEST = {
    rows: 251, row_padding_bytes: 1024, writers: 5, publish_hz: 5,
    manual_hz: 10, seed: 261103, duration_sec: 2, repetitions: 3
  }.freeze

  def self.snapshot
    {
      "phase" => "complete", "tick_sequence" => 1, "daemon" => { "pid" => 1 },
      "tasks" => Array.new(MANIFEST.fetch(:rows)) do |index|
        { "task_id" => index.to_s, "stage" => "4-execute", "detail" => "x" * MANIFEST.fetch(:row_padding_bytes) }
      end
    }
  end

  def self.run(root:)
    path = File.join(root, "runtime.sqlite3")
    database = Hive::RuntimeControlPlane::Database.new(path: path)
    database.migrate!
    database.disconnect
    document = snapshot
    pids = Array.new(MANIFEST.fetch(:writers)) do |writer|
      fork do
        measurements = []
        connection = Hive::RuntimeControlPlane::Database.new(
          path: path, checkpoint_role: writer.zero? ? :daemon_backed : :manual,
          transaction_observer: ->(item) { measurements << item }
        )
        connection.open!
        publisher = Hive::RuntimeControlPlane::OperationalRepository.new(database: connection)
        period = 1.0 / MANIFEST.fetch(writer.zero? ? :publish_hz : :manual_hz)
        ticks = (MANIFEST.fetch(:duration_sec) / period).to_i
        ticks.times do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if writer.zero?
            publisher.publish(document)
          else
            connection.transaction(operation: "qualification.manual_bookkeeping") do |db|
              db[:installations].update(next_task_id: writer)
            end
            connection.read { |db| db[:daemon_runtime].get(:observation_json) }
          end
          remaining = period - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          sleep remaining if remaining.positive?
        end
        connection.disconnect
        File.write(File.join(root, "writer-#{writer}.json"), JSON.generate(measurements))
        exit! 0
      end
    end
    pids.each { |pid| raise "qualification child failed" unless Process.wait2(pid).last.success? }
    measurements = Dir.glob(File.join(root, "writer-*.json")).flat_map { |name| JSON.parse(File.read(name)) }
    {
      manifest: MANIFEST.merge(snapshot_bytes: Hive::RuntimeControlPlane::Codec.dump_json(document).bytesize),
      roles: { daemon_backed: 0, manual: 4096 },
      writers: measurements.group_by { |item| item.fetch("operation") }.transform_values do |items|
        {
          count: items.size, long_holds: items.count { |item| item.fetch("hold_sec").to_f > 1 },
          wait_sec: distribution(items.map { |item| item.fetch("wait_sec") }),
          hold_sec: distribution(items.map { |item| item.fetch("hold_sec") })
        }
      end
    }
  end

  def self.distribution(values)
    sorted = values.compact.sort
    { p50: sorted[(sorted.length * 0.50).floor], p95: sorted[(sorted.length * 0.95).floor], max: sorted.last }
  end
end
