require "test_helper"
require "open3"
require "timeout"
require "json_schemer"
require "hive/commands/init"
require "hive/daemon/quiescence"

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
      [[], ["--json"]].each do |flags|
        with_lock(home) do
          result = cli("status", *flags)
          assert_equal 0, result[:exit], result.inspect
          assert_includes result[:events], "reserve_begin"
          assert_budget(result, 1.0)
          assert_clean_errors(result)
          if flags.empty?
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
      [[], ["--json=true"]].each do |flags|
        with_lock(home) do
          result = cli(*flags, "new", name, "busy acceptance task")
          assert_equal 75, result[:exit], result.inspect
          assert_includes result[:events], "reserve_begin"
          registration_wait = result[:finished_at] - result[:reserve_started_at]
          assert_operator registration_wait, :>=, 14.8
          puts "CONTENTION persistent_registration_wait=#{registration_wait.round(3)} process=#{result[:duration].round(3)}"
          assert_operator result[:duration], :>=, 15
          assert_operator result[:duration], :<, 15 + STARTUP_TOLERANCE
          assert_equal "runtime database busy, retry\n", result[:stderr]
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
          sleep([deadline - monotonic, 0].max) while monotonic < deadline
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
      [[], ["--json"]].each do |flags|
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
      [:transaction, :checkpoint].each do |operation|
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
        result = {stdout: stdout.value, stderr: stderr.value, exit: process.value.exitstatus,
                  events: events, duration: monotonic - started, finished_at: monotonic,
                  reserve_started_at: reserve_started_at}
      end
    rescue Exception
      Process.kill("KILL", process.pid) if process.alive?
      raise
    end
    result
  ensure
    [events_read, events_write, control_read, control_write].each { |io| io&.close unless io&.closed? }
  end

  def assert_budget(result, expected)
    waited = Float(result[:events].find { |event| event.start_with?("waited:") }.split(":").last)
    assert_in_delta expected, waited, 0.15 if expected
    assert_operator waited, :<=, 1.15
    assert_operator result[:duration], :<, 1 + STARTUP_TOLERANCE
    puts "CONTENTION status_wait=#{waited.round(3)} process=#{result[:duration].round(3)}"
  end

  def assert_clean_errors(result)
    assert_equal "", result[:stderr], result.inspect
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
