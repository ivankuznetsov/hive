require "test_helper"
require "timeout"
require "rbconfig"
require_relative "../support/runtime_contention_attempt_fixture"
require_relative "../support/runtime_database_contention_workload"
require_relative "../support/runtime_checkpoint_workload"

class RuntimeDatabaseContentionTest < Minitest::Test
  include HiveTestHelper
  include RuntimeContentionAttemptFixture

  OPERATIONS = %i[claim first_heartbeat checkpoint heartbeat terminalize].freeze
  REPORTS = {}

  def test_daemon_and_four_supervisors_recover_each_held_bookkeeping_operation_without_duplicate_execution
    OPERATIONS.each do |operation|
      with_tmp_dir do |root|
        report = run_supervisors(root, operation: operation, exhaust: false)
        assert_equal [ 0, 0, 0, 0 ], report.fetch(:exit_statuses), report.inspect
        assert_equal [ 1, 1, 1, 1 ], report.fetch(:invocations)
        assert_equal [ "succeeded" ] * 4, report.fetch(:outcomes)
        assert_equal [ 4096 ] * 4, report.fetch(:manual_pragmas)
        assert_equal 0, report.fetch(:daemon).fetch("autocheckpoint")
        assert_operator report.fetch(:daemon).fetch("publications"), :>, 0
        assert_operator report.fetch(:daemon).fetch("reads"), :>, 0
        assert_equal RuntimeDatabaseContentionWorkload::MANIFEST.fetch(:publish_hz), report.fetch(:daemon).fetch("publish_hz")
        assert_operator report.fetch(:daemon).fetch("peak_wal_bytes"), :>, 0
        assert_operator report.fetch(:duration_sec), :<, 20
        emit_report(operation, report)
      end
    end
  end

  def test_held_lock_exhaustion_is_typed_and_terminal_completion_replays_after_restart
    OPERATIONS.each do |operation|
      with_tmp_dir do |root|
        report = run_supervisors(root, operation: operation, exhaust: true)
        assert_equal [ Hive::ExitCodes::TEMPFAIL ] * 4, report.fetch(:exit_statuses), report.inspect
        expected_invocations = %i[claim first_heartbeat].include?(operation) ? 0 : 1
        assert_equal [ expected_invocations ] * 4, report.fetch(:invocations)
        assert_equal [ "succeeded" ] * 4, report.fetch(:outcomes) if operation == :terminalize
        assert report.fetch(:busy_reasons).all? { |reason| reason == "runtime_bookkeeping_busy" }
        assert_operator report.fetch(:duration_sec), :<, 20
        emit_report("#{operation}_exhausted", report)
      end
    end
  end

  def test_fixed_writer_comparison_and_checkpoint_starvation_fixtures_are_executable
    with_tmp_dir do |root|
      repetitions = Array.new(RuntimeDatabaseContentionWorkload::MANIFEST.fetch(:repetitions)) do |index|
        repetition_root = File.join(root, "repetition-#{index}")
        Dir.mkdir(repetition_root)
        comparison = RuntimeDatabaseContentionWorkload.run(root: repetition_root)
        assert_equal 5, comparison.fetch(:manifest).fetch(:writers)
        assert_equal 251, comparison.fetch(:manifest).fetch(:rows)
        assert_equal 2, comparison.fetch(:writers).size
        assert comparison.fetch(:writers).values.all? { |writer| writer.fetch(:count).positive? }
        comparison
      end
      emit_report("fixed_writer_comparison", manifest: repetitions.first.fetch(:manifest), repetitions: repetitions)
    end
    with_tmp_dir do |root|
      checkpoint = RuntimeCheckpointWorkload.run(root: root)
      assert_operator checkpoint.fetch(:peak_wal_bytes), :>, 16 * 1024 * 1024
      assert checkpoint.fetch(:released_reader_drain).fetch(:complete)
      assert checkpoint.fetch(:upgrade_truncate_complete)
      assert checkpoint.fetch(:lifecycle_checkpoint).fetch(:complete)
      emit_report("checkpoint_starvation", checkpoint)
    end
  end

  private

  def run_supervisors(root, operation:, exhaust:)
    started = monotonic
    store = Hive::Attempts::Repository.new(root: root, migrate: true)
    path = store.database.path
    release_worker = File.join(root, "release-worker")
    workers_wait = %i[checkpoint heartbeat].include?(operation)
    4.times do |index|
      counter = File.join(root, "invocations-#{index}")
      script = <<~'RUBY'
        File.open(ARGV[0], "a") { |f| f.puts(Process.pid) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until File.exist?(ARGV[1]) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.005
        end
      RUBY
      create_contention_attempt(
        store, id: index.to_s,
        worker: [ RbConfig.ruby, "-e", script, counter, release_worker ]
      )
    end
    File.write(release_worker, "go") unless workers_wait
    store.database.disconnect
    ready_read, ready_write = IO.pipe
    go_read, go_write = IO.pipe
    daemon_stop = File.join(root, "stop-daemon")
    daemon = fork { daemon_workload(root, path, daemon_stop) }
    children = Array.new(4) do |index|
      fork do
        ready_read.close
        go_write.close
        measurements = []
        database = Hive::RuntimeControlPlane::Database.new(
          path: path, transaction_observer: ->(item) { measurements << item }
        )
        child_store = Hive::Attempts::Repository.new(root: root, database: database)
        registry = Hive::RuntimeControlPlane::ProcessRegistry.new(database: database)
        reservation = registry.reserve!(origin: "manual", role: "attempt_supervisor", attempt_id: index.to_s)
        pragma = database.read { |db| db.fetch("PRAGMA wal_autocheckpoint").first.values.first }
        original = child_store.method(operation)
        first = true
        child_store.define_singleton_method(operation) do |*args, **options|
          if first
            first = false
            if %i[checkpoint heartbeat].include?(operation)
              Timeout.timeout(5) { sleep 0.005 until File.exist?(File.join(root, "invocations-#{index}")) }
            end
            ready_write.write("r")
            go_read.read(1)
          end
          original.call(*args, **options)
        end
        supervisor = Hive::Attempts::Supervisor.new(
          store: child_store, attempt_id: index.to_s,
          claim_io: StringIO.new(RuntimeContentionAttemptFixture::SECRET),
          heartbeat_sec: 0.01, stale_sec: 1, bookkeeping_timeout_sec: exhaust ? 0.2 : 5,
          busy_tolerance_sec: exhaust ? 0.2 : 5, kill_grace_sec: 0.01,
          process_registry: registry, reservation_id: reservation.id,
          random: -> { 0.5 }
        )
        status = supervisor.run
        reservation.release_fence!
        current = child_store.fetch(index.to_s)
        pending = child_store.pending_bookkeeping.read(current)
        File.write(File.join(root, "supervisor-#{index}.json"), JSON.generate(
          status: status, autocheckpoint: pragma, measurements: measurements,
          reason: pending.document && pending.document["reason"]
        ))
        database.disconnect
        exit! 0
      rescue Exception => error
        warn "qualification supervisor #{index}: #{error.full_message}"
        exit! 1
      end
    end
    ready_write.close
    go_read.close
    Timeout.timeout(15) { raise "supervisor barrier failed" unless ready_read.read(4)&.bytesize == 4 }
    locked_read, locked_write = IO.pipe
    holder = fork do
      locked_read.close
      connection = SQLite3::Database.new(path)
      connection.busy_timeout(5_000)
      connection.execute("BEGIN IMMEDIATE")
      locked_write.write("l")
      locked_write.close
      sleep(exhaust ? 0.6 : 0.25)
      connection.execute("ROLLBACK")
      connection.close
      exit! 0
    end
    locked_write.close
    Timeout.timeout(10) { raise "holder barrier failed" unless locked_read.read(1) == "l" }
    go_write.write("gggg")
    go_write.close
    raise "holder failed" unless Process.wait2(holder).last.success?
    File.write(release_worker, "go")
    Timeout.timeout(15) do
      children.each { |pid| raise "supervisor child failed" unless Process.wait2(pid).last.success? }
    end
    File.write(daemon_stop, "stop")
    Timeout.timeout(10) { raise "daemon failed" unless Process.wait2(daemon).last.success? }
    summaries = Array.new(4) { |index| JSON.parse(File.read(File.join(root, "supervisor-#{index}.json"))) }
    # Reopen all observers after both writer and wrappers exit. A pending
    # success must win before any missing-owner loss or replacement admission.
    restarted = Hive::Attempts::Repository.new(root: root)
    if operation == :terminalize && exhaust
      Hive::Attempts::Reconciler.new(store: restarted).reconcile
      Hive::Attempts::Reconciler.new(store: restarted).reconcile
    end
    {
      operation: operation, lock_hold_sec: exhaust ? 0.6 : 0.25,
      configured_budget_sec: exhaust ? 0.2 : 5, duration_sec: monotonic - started,
      production_prestart_budget_sec: 30, production_live_budget_sec: 600,
      exit_statuses: summaries.map { |item| item.fetch("status") },
      manual_pragmas: summaries.map { |item| item.fetch("autocheckpoint") },
      busy_reasons: summaries.map { |item| item["reason"] },
      invocations: Array.new(4) { |index| File.exist?(File.join(root, "invocations-#{index}")) ? File.readlines(File.join(root, "invocations-#{index}")).size : 0 },
      outcomes: Array.new(4) { |index| restarted.fetch(index.to_s).outcome },
      daemon: JSON.parse(File.read(File.join(root, "daemon.json"))),
      transactions: summaries.flat_map { |item| item.fetch("measurements") }
    }
  ensure
    [ *children, holder, daemon ].compact.each do |pid|
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    [ ready_read, ready_write, go_read, go_write, locked_read, locked_write ].compact.each { |io| io.close unless io.closed? }
    restarted&.database&.disconnect
    store&.database&.disconnect
  end

  def daemon_workload(root, path, stop)
    measurements = []
    database = Hive::RuntimeControlPlane::Database.new(
      path: path, checkpoint_role: :daemon_backed,
      transaction_observer: ->(item) { measurements << item }
    )
    store = Hive::Attempts::Repository.new(root: root, database: database)
    publisher = Hive::RuntimeControlPlane::OperationalRepository.new(database: database)
    reconciler = Hive::Attempts::Reconciler.new(store: store)
    publications = reads = peak_wal_bytes = 0
    publish_hz = RuntimeDatabaseContentionWorkload::MANIFEST.fetch(:publish_hz)
    pragma = database.read { |db| db.fetch("PRAGMA wal_autocheckpoint").first.values.first }
    until File.exist?(stop)
      publisher.publish(RuntimeDatabaseContentionWorkload.snapshot)
      publications += 1
      reconciler.reconcile(timeout_sec: 0.05)
      database.read { |db| db[:daemon_runtime].get(:observation_json) }
      reads += 1
      peak_wal_bytes = [ peak_wal_bytes, database.wal_bytes ].max
      sleep 1.0 / publish_hz
    end
    File.write(File.join(root, "daemon.json"), JSON.generate(
      autocheckpoint: pragma, publications: publications, reads: reads, measurements: measurements,
      publish_hz: publish_hz, peak_wal_bytes: peak_wal_bytes
    ))
    database.disconnect
    exit! 0
  rescue Exception => error
    warn "qualification daemon: #{error.full_message}"
    exit! 1
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def emit_report(name, report)
    REPORTS[name] = report
    evidence = File.expand_path("../../tmp/runtime-database-contention-evidence.json", __dir__)
    FileUtils.mkdir_p(File.dirname(evidence))
    File.write(evidence, JSON.pretty_generate(REPORTS))
    puts "runtime contention qualification #{name}: #{report.fetch(:duration_sec, "complete")}"
  end
end
