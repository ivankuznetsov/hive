require "test_helper"
require "open3"
require "timeout"
require "rbconfig"
require "json_schemer"
require "hive/commands/init"
require "hive/daemon/quiescence"
require_relative "../support/runtime_contention_attempt_fixture"
require_relative "../support/runtime_database_contention_workload"
require_relative "../support/runtime_checkpoint_workload"

class RuntimeDatabaseContentionTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  PROBE = File.join(ROOT, "test/support/runtime_contention_probe.rb")
  # Startup and scheduler time is outside SQLite's waiting allowance. The
  # watchdog also bounds a broken test; measured callback time proves status.
  STARTUP_TOLERANCE = 10
  WATCHDOG = 35

  def test_persistent_registration_lock_gives_partial_human_and_json_status
    with_fixture do |home, _project, _name|
      [ [], [ "--json" ], %w[--json true], %w[--json false] ].each do |flags|
        with_lock(home) do
          result = cli("status", *flags)
          assert_equal 0, result[:exit], result.inspect
          assert_includes result[:events], "reserve_begin"
          assert_budget(result, 1.0)
          assert_clean_errors(result)
          if flags.empty? || flags == %w[--json false]
            assert_includes result[:stdout], "RUNNING TASKS UNAVAILABLE"
            refute_includes result[:stdout], "NO RUNNING TASKS"
            assert_equal 1, result[:stdout].scan("runtime database busy").length
          else
            assert_partial(JSON.parse(result[:stdout]))
          end
        end
      end
    end
  end

  def test_exclusive_lock_during_activation_uses_partial_status_without_registration
    with_fixture do |home, _project, _name|
      blocker = lock_database(home, exclusive: true)
      result = cli("--json=true", "status")
      assert_equal 0, result[:exit], result.inspect
      refute_includes result[:events], "reserve_begin"
      refute_includes result[:events], "lease_scan"
      assert_partial(JSON.parse(result[:stdout]))
      assert_budget(result, 1.0)
      assert_clean_errors(result)
    ensure
      blocker&.close
    end
  end

  def test_ordinary_registration_exhausts_retained_fifteen_second_timeout_without_action
    with_fixture do |home, project, name|
      [ [], [ "--json=true" ] ].each do |flags|
        with_lock(home) do
          result = cli(*flags, "new", name, "busy acceptance task")
          assert_equal 75, result[:exit], result.inspect
          assert_includes result[:events], "reserve_begin"
          registration_wait = result[:finished_at] - result[:reserve_started_at]
          assert_operator registration_wait, :>=, 14.8
          puts "CONTENTION persistent_registration_wait=#{registration_wait.round(3)} process=#{result[:duration].round(3)}"
          assert_operator result[:duration], :>=, 15
          assert_operator result[:duration], :<, 15 + STARTUP_TOLERANCE
          assert_equal [ target_announcement(name), "runtime database busy, retry\n" ], result[:stderr].lines
          assert_empty task_files(project)
          if flags.empty?
            assert_equal "", result[:stdout]
          else
            payload = JSON.parse(result[:stdout])
            assert_schema(payload, "hive-runtime-maintenance")
            assert_equal false, payload.fetch("ok")
            assert_equal 75, payload.fetch("exit_code")
            assert_equal "runtime", payload.fetch("error_kind")
            assert_equal "runtime_database_busy", payload.fetch("runtime_code")
            assert_equal "new", payload.fetch("action")
            refute_empty payload.fetch("next_action")
          end
        end
      end
    end
  end

  def test_transient_status_and_ordinary_locks_allow_normal_execution
    with_fixture do |home, project, name|
      with_lock(home) do |release|
        result = cli("status", "--json") do |event|
          release.call if event == "busy"
        end
        assert_equal 0, result[:exit], result.inspect
        assert JSON.parse(result[:stdout]).fetch("complete")
        assert_budget(result, nil)
        assert_clean_errors(result)
      end
      with_lock(home) do |release|
        released_after = nil
        result = cli("new", name, "transient acceptance task") do |event|
          next unless event == "reserve_begin" && released_after.nil?
          started = monotonic
          # The BEGIN trace proves the target operation has started. Release
          # the held lock on a monotonic deadline after the old 5s window.
          deadline = started + 5.2
          sleep([ deadline - monotonic, 0 ].max) while monotonic < deadline
          released_after = monotonic - started
          release.call
        end
        assert_operator released_after, :>, 5
        assert_operator released_after, :<, 14
        assert_equal 0, result[:exit], result.inspect
        assert_equal 1, task_files(project).length
        assert_clean_errors(result)
        puts "CONTENTION transient_registration_wait=#{released_after.round(3)} process=#{result[:duration].round(3)}"
      end
    end
  end

  def test_uncontended_commands_preserve_success
    with_fixture do |_home, project, name|
      [ [], [ "--json" ] ].each do |flags|
        result = cli("status", *flags)
        assert_equal 0, result[:exit], result.inspect
        assert_clean_errors(result)
        if flags.empty?
          assert_includes result[:stdout], "NO RUNNING TASKS"
          refute_includes result[:stdout], "STATUS PARTIAL"
        else
          payload = JSON.parse(result[:stdout])
          assert_schema(payload, "hive-running-status")
          assert payload.fetch("complete")
        end
      end
      result = cli("new", name, "uncontended acceptance task")
      assert_equal 0, result[:exit], result.inspect
      assert_equal 1, task_files(project).length
      assert_clean_errors(result)
    end
  end

  def test_read_conflicting_lock_after_registration_retains_row_and_resume_reconciles_it
    with_fixture do |home, _project, _name|
      blocker = nil
      result = cli("status", "--json", phase: "reader") do |event, control|
        next unless event == "registered"
        blocker = lock_database(home, exclusive: true)
        reader = SQLite3::Database.new(Hive::Paths.runtime_control_plane_path(home), readonly: true)
        reader.busy_timeout = 0
        assert_raises(SQLite3::BusyException) { reader.execute("SELECT * FROM task_leases") }
        reader.close
        control.write("1")
      end
      assert_equal 0, result[:exit], result.inspect
      assert_includes result[:events], "lease_scan"
      assert_partial(JSON.parse(result[:stdout]))
      assert_budget(result, 1.0)
      assert_clean_errors(result)
      blocker.close
      blocker = nil
      assert_retained_and_reconcile(home)
    ensure
      blocker&.close
    end
  end

  def test_exit_cleanup_uses_remaining_status_budget_and_preserves_exit_zero
    with_fixture do |home, _project, _name|
      blocker = nil
      result = cli("status", "--json", phase: "cleanup") do |event, control|
        next unless event == "output"
        blocker = lock_database(home)
        control.write("1")
      end
      assert_equal 0, result[:exit], result.inspect
      assert JSON.parse(result[:stdout]).fetch("complete")
      assert_budget(result, 1.0)
      assert_clean_errors(result)
      blocker.close
      blocker = nil
      assert_retained_and_reconcile(home)
    ensure
      blocker&.close
    end
  end

  def test_actual_adapter_preserves_budget_after_transaction_and_checkpoint_restoration
    with_fixture do |home, _project, _name|
      database = Hive::RuntimeControlPlane.database.open!
      connection = database.read { |db| db }
      blocker = nil
      [ :transaction, :checkpoint ].each do |operation|
        blocker = SQLite3::Database.new(database.path)
        if operation == :transaction
          blocker.execute("BEGIN IMMEDIATE")
        else
          blocker.execute("BEGIN")
          blocker.execute("SELECT * FROM installations")
          database.transaction { |db| db[:installations].update(activation_epoch: 1) }
        end
        now = 0.0
        released = false
        Hive::RuntimeControlPlane::ContentionBudget.with(
          seconds: 0.1, clock: -> { now }, wait: ->(seconds) {
            now += seconds
            if !released && now >= 0.03
              blocker.execute("ROLLBACK")
              released = true
            end
          }
        ) do |budget|
          if operation == :transaction
            database.transaction(timeout_sec: 2) { true }
          else
            assert database.checkpoint!(timeout_sec: 2).fetch(:complete)
          end
          assert_in_delta 0.03, budget.waited
          blocker.execute("BEGIN IMMEDIATE")
          # Bypass another checkout: the ensure path itself must have left
          # SQLite's real callback installed after restoring the integer pragma.
          assert_raises(Sequel::DatabaseError) { connection.transaction(mode: :immediate) { true } }
          assert_in_delta 0.1, budget.waited
        end
        assert_equal 15_000, connection.fetch("PRAGMA busy_timeout").first.values.first
        blocker.close
        blocker = nil
      end
    ensure
      blocker&.close
    end
  end

  private

  def with_fixture
    with_tmp_global_config do |home|
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        Hive::RuntimeControlPlane.disconnect
        yield home, project, File.basename(project)
      end
    end
  end

  def lock_database(home, exclusive: false)
    database = SQLite3::Database.new(Hive::Paths.runtime_control_plane_path(home))
    database.busy_timeout = 0
    database.execute("PRAGMA locking_mode = EXCLUSIVE") if exclusive
    database.execute(exclusive ? "BEGIN EXCLUSIVE" : "BEGIN IMMEDIATE")
    database
  end

  def with_lock(home)
    database = lock_database(home)
    released = false
    release = -> { unless released; database.execute("ROLLBACK"); released = true; end }
    yield release
  ensure
    database&.execute("ROLLBACK") unless released
    database&.close
  end

  def cli(*argv, phase: nil)
    events_read, events_write = IO.pipe
    control_read, control_write = IO.pipe
    events = []
    started = monotonic
    reserve_started_at = nil
    environment = {
      "CONTENTION_EVENTS_FD" => events_write.fileno.to_s,
      "CONTENTION_CONTROL_FD" => control_read.fileno.to_s,
      "CONTENTION_PHASE" => phase,
      "HIVE_RUNTIME_CHILD_RESERVATION_ID" => nil, "HIVE_LAUNCH_GATE_FD" => nil
    }
    result = nil
    Open3.popen3(environment, RbConfig.ruby, "-I#{ROOT}/lib", "-r#{PROBE}",
                 File.join(ROOT, "bin/hive"), *argv,
                 events_write.fileno => events_write, control_read.fileno => control_read) do |input, output, errors, process|
      input.close
      events_write.close
      control_read.close
      stdout = Thread.new { output.read }
      stderr = Thread.new { errors.read }
      Timeout.timeout(WATCHDOG) do
        events_read.each_line do |line|
          event = line.chomp
          events << event
          reserve_started_at ||= monotonic if event == "reserve_begin"
          yield event, control_write if block_given?
        end
        result = { stdout: stdout.value, stderr: stderr.value, exit: process.value.exitstatus,
                  events: events, duration: monotonic - started, finished_at: monotonic,
                  reserve_started_at: reserve_started_at }
      end
    rescue Exception
      Process.kill("KILL", process.pid) if process.alive?
      raise
    end
    result
  ensure
    [ events_read, events_write, control_read, control_write ].each { |io| io&.close unless io&.closed? }
  end

  def assert_budget(result, expected)
    waited = Float(result[:events].find { |event| event.start_with?("waited:") }.split(":").last)
    assert_in_delta expected, waited, 0.15 if expected
    assert_operator waited, :<=, 1.15
    assert_operator result[:duration], :<, 1 + STARTUP_TOLERANCE
    puts "CONTENTION status_wait=#{waited.round(3)} process=#{result[:duration].round(3)}"
  end

  # Local mutations announce their target before dispatch (remote CLI policy).
  # The announcement is not an error; every other stderr byte is.
  TARGET_ANNOUNCEMENT = /\Ahive: context=local installation=local authority=unrestricted-local-operator target=[^\r\n]*\n\z/

  def target_announcement(name)
    "hive: context=local installation=local authority=unrestricted-local-operator target=#{name}\n"
  end

  def assert_clean_errors(result)
    diagnostics = result[:stderr].lines.reject { |line| line.match?(TARGET_ANNOUNCEMENT) }.join
    assert_equal "", diagnostics, result.inspect
    refute_match(/BusyException|DatabaseError|backtrace|database_corrupt|external backup/, result[:stdout])
  end

  def assert_partial(payload)
    assert_schema(payload, "hive-running-status")
    assert payload.fetch("ok")
    refute payload.fetch("complete")
    refute payload.fetch("observed_count_exact")
    refute payload.fetch("omitted_count_exact")
    refute payload.fetch("truncated")
    refute payload.dig("source", "scan_truncated")
    %w[count observed_count omitted_count].each { |name| assert_equal 0, payload.fetch(name) }
  end

  def assert_schema(payload, name)
    assert_empty JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name)))).validate(payload).to_a
  end

  def task_files(project) = Dir[File.join(project, ".hive-state/stages/*/*/idea.md")]
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def assert_retained_and_reconcile(home)
    database = Hive::RuntimeControlPlane::Database.new(path: Hive::Paths.runtime_control_plane_path(home))
    row = database.read { |db| db[:owned_processes].first }
    assert_equal "running", row.fetch(:state)
    assert_nil row[:stopped_at]
    lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
    lifecycle.begin_quiesce!(deadline_monotonic: monotonic + 5, boot_id: "test", shutdown_grace_sec: 1)
    result = Hive::Daemon::Resume.new(state_home: home, database: database,
                                    service_restorer: ->(**_) { [] }).call
    assert result.resumed, result.inspect
    assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
    assert_equal "resume_reconciled", database.read { |db| db[:owned_processes].get(:unknown_reason) }
  ensure
    database&.disconnect
  end
end

# Attempt bookkeeping under a held writer lock: a daemon workload plus four
# supervisors recover or exhaust each bookkeeping write without re-execution.
class RuntimeAttemptBookkeepingContentionTest < Minitest::Test
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
