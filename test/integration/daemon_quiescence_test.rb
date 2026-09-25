require "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "timeout"
require "hive/attempts/process_custody"
require "hive/daemon/quiescence"
require "hive/daemon/status_report"
require "hive/runtime_control_plane/installation"
require "hive/runtime_control_plane/launch_coverage"
require "hive/runtime_control_plane/process_registry"
require "hive/runtime_control_plane/quiescence_upgrade"

class DaemonQuiescenceIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  UNSUPPORTED_CUSTODY = Hive::Attempts::ProcessCustody.unsupported(
    "increment-one integration fixture has no delegated custody"
  )

  def test_idle_registry_checkpoints_and_publishes_a_same_generation_backup_pair
    with_runtime_home do |root, env|
      with_trapped_process(root, "unrelated") do |pid, signal_path|
        output, errors, process = run_hive(env, "daemon", "quiesce", "--timeout", "2", "--json")

        assert_equal 0, process.exitstatus, errors
        quiesced = JSON.parse(output)
        assert_equal true, quiesced.fetch("paused")
        assert_equal "paused", quiesced.fetch("result")
        assert_equal true, quiesced.dig("checkpoint", "complete")
        assert_equal 0, quiesced.dig("checkpoint", "busy")
        assert_equal quiesced.fetch("generation"), quiesced.dig("proof", "generation")
        assert_equal [], quiesced.fetch("remaining")
        assert File.file?(Hive::Paths.runtime_quiescence_proof_path(root))

        status_output, status_errors, status_process = run_hive(
          env, "daemon", "status", "--json"
        )
        assert_equal 1, status_process.exitstatus, status_errors
        status = JSON.parse(status_output)
        assert_equal "paused", status.dig("lifecycle", "phase")
        assert_equal quiesced.fetch("generation"), status.dig("lifecycle", "generation")
        assert_equal true, status.dig("lifecycle", "proof", "valid")
        assert_equal true, status.dig("lifecycle", "liveness", "clear")
        assert_equal true, status.dig("quiescence_capability", "eligible")

        assert_process_alive(pid)
        refute_path_exists signal_path,
                           "an unrelated real process must never enter the owned stop inventory"
      end
    end
  end

  def test_agent_attempt_root_is_refused_before_admission_or_signals_change
    with_runtime_database do |root, database|
      with_trapped_process(root, "attempt-root") do |pid, signal_path|
        registry = registry_for(root, database)
        registration = register_process(
          registry, pid, origin: "attempt", role: "attempt_wrapper",
          attempt_id: "attempt-in-flight"
        )
        before = lifecycle_tuple(database)

        result = coordinator(root, database, registry: registry).call

        refute result.paused
        assert_equal "ownership_unverifiable", result.reason
        assert_equal "agent_attempt_root", result.capability.reason
        assert result.admission_open
        assert_nil result.generation
        assert_equal before, lifecycle_tuple(database)
        assert_equal "attempt-in-flight", result.remaining.first.fetch("attempt_id")
        assert_process_alive(pid)
        refute_path_exists signal_path
      ensure
        registration&.fetch(:reservation)&.release_fence!
      end
    end
  end

  def test_unproven_registered_surface_is_refused_before_admission_or_signals_change
    with_runtime_database do |root, database|
      with_trapped_process(root, "unproven-service") do |pid, signal_path|
        registry = registry_for(root, database)
        registration = register_process(
          registry, pid, origin: "daemon_child", role: "service",
          service_identity: "hive-daemon", proven_child_safe: true
        )
        before = lifecycle_tuple(database)

        result = coordinator(root, database, registry: registry).call

        refute result.paused
        assert_equal "ownership_unverifiable", result.reason
        assert_equal "unproven_launch_surface", result.capability.reason
        assert result.admission_open
        assert_nil result.generation
        assert_equal before, lifecycle_tuple(database)
        assert_process_alive(pid)
        refute_path_exists signal_path
        assert_empty Hive::RuntimeControlPlane::LaunchCoverage::ROWS.select {
          |row| row.fetch(:child_safe)
        }, "increment 1 must not invent a non-empty registered-only success surface"
      ensure
        registration&.fetch(:reservation)&.release_fence!
      end
    end
  end

  def test_detached_descendant_keeps_its_attempt_root_unverifiable_after_controller_restart
    with_runtime_database do |root, database|
      tree = spawn_detached_tree(root)
      registry = registry_for(root, database)
      registration = register_process(
        registry, tree.fetch(:root_pid), origin: "attempt", role: "attempt_wrapper",
        attempt_id: "detached-attempt"
      )
      File.write(tree.fetch(:release_path), "release\n")
      Process.wait(tree.fetch(:root_pid))
      tree[:root_pid] = nil
      assert_process_alive(tree.fetch(:descendant_pid))

      first = coordinator(root, database, registry: registry).call
      restarted = coordinator(root, database, registry: registry).call

      [ first, restarted ].each do |result|
        refute result.paused
        assert_equal "ownership_unverifiable", result.reason
        assert_equal "agent_attempt_root", result.capability.reason
        assert result.admission_open
        assert_nil result.generation
        assert_equal "detached-attempt", result.remaining.first.fetch("attempt_id")
      end
      assert_equal "running", lifecycle_tuple(database).fetch(:phase)
      assert_process_alive(tree.fetch(:descendant_pid))
      refute_path_exists tree.fetch(:signal_path)
    ensure
      registration&.fetch(:reservation)&.release_fence!
      terminate_process(tree && tree[:root_pid])
      terminate_process(tree && tree[:descendant_pid])
    end
  end

  def test_post_proof_hivebox_supervisor_respawn_downgrades_status_without_database_write
    with_runtime_database do |root, database|
      paused = coordinator(root, database, registry: registry_for(root, database)).call
      assert paused.paused, paused.to_h.inspect
      database_bytes = File.binread(database.path)

      with_trapped_process(root, "hivebox-supervisor") do |pid, signal_path|
        payload = with_env("HIVEBOX_SUPERVISOR_PID" => pid.to_s) do
          status_payload(root)
        end

        assert_equal "paused", payload.dig("lifecycle", "durable_phase")
        assert_equal "quiescing", payload.dig("lifecycle", "phase")
        assert_equal true, payload.dig("lifecycle", "proof", "valid")
        assert_equal false, payload.dig("quiescence_capability", "eligible")
        assert_equal "legacy_process_unregistered",
                     payload.dig("quiescence_capability", "reason")
        assert_equal "hivebox_supervisor",
                     payload.dig("quiescence_capability", "disqualifying_inventory", 0,
                                 "service_identity")
        assert_equal database_bytes, File.binread(database.path),
                     "read-only status must not mutate the paused database"
        assert_process_alive(pid)
        refute_path_exists signal_path
      end

      assert_equal "paused", status_payload(root).dig("lifecycle", "phase")
    end
  end

  def test_finalization_crash_retries_the_same_generation_and_never_exposes_false_paused
    with_runtime_home do |root, _env|
      marker = File.join(root, "publish-entered")
      script = <<~'RUBY'
        require "hive/daemon/quiescence"

        class BlockingProof
          def initialize(marker)
            @marker = marker
          end

          def verify(**)
            Hive::Daemon::ProofVerdict.new(valid: false, reason: "proof_missing", payload: nil)
          end

          def remove! = false

          def publish!(**)
            File.write(@marker, "publishing\n")
            sleep 60
          end
        end

        Hive::Daemon::Quiescence.new(
          state_home: ARGV.fetch(0), timeout_sec: 30,
          proof_store: BlockingProof.new(ARGV.fetch(1))
        ).call
      RUBY
      pid = Process.spawn(
        RbConfig.ruby, "-Ilib", "-e", script, root, marker,
        in: File::NULL, out: File::NULL, err: File::NULL
      )
      wait_for_path(marker)
      Process.kill("KILL", pid)
      Process.wait(pid)
      pid = nil

      crashed = lifecycle_from_home(root)
      assert_equal "paused", crashed.fetch(:phase),
                   "the candidate is durable before proof publication starts"
      refute_path_exists Hive::Paths.runtime_quiescence_proof_path(root)
      assert_equal "quiescing", status_payload(root).dig("lifecycle", "phase")

      result = Hive::Daemon::Quiescence.new(state_home: root, timeout_sec: 2).call

      assert result.paused, result.to_h.inspect
      assert_equal crashed.fetch(:generation), result.generation
      assert_equal true, result.checkpoint.fetch(:complete)
      assert_equal result.generation, result.proof.fetch("generation")
      assert_equal "paused", status_payload(root).dig("lifecycle", "phase")
    ensure
      terminate_process(pid)
    end
  end

  def test_resume_reconciles_missing_owned_identity_before_new_launch_is_admitted
    with_runtime_database do |root, database|
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      closed = lifecycle.begin_quiesce!(
        deadline_monotonic: monotonic_now + 30, boot_id: "integration-boot",
        shutdown_grace_sec: 5
      )
      insert_missing_owned_process(database, closed.generation)

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 2
      ).call

      assert result.resumed, result.to_h.inspect
      assert result.admission_reopened
      assert_equal closed.generation, result.generation
      assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
      assert_equal "resume_reconciled",
                   database.read { |db| db[:owned_processes].get(:unknown_reason) }

      reservation = registry_for(root, database).reserve!(
        origin: "direct_cli", role: "post_resume_probe", timeout_sec: 1
      )
      assert reservation.id
    ensure
      reservation&.release_fence!
    end
  end

  def test_version_skewed_paused_restore_upgrades_in_place_before_resume_reopens
    with_runtime_home do |root, env|
      path = Hive::Paths.runtime_control_plane_path(root)
      database = Hive::RuntimeControlPlane::Database.new(path: path).open!
      installation_id = seed_terminal_attempt_and_payload(database)
      database.disconnect

      output, errors, process = run_hive(
        env, "daemon", "quiesce", "--timeout", "2", "--json"
      )
      assert_equal 0, process.exitstatus, errors
      generation = JSON.parse(output).fetch("generation")
      proof_path = Hive::Paths.runtime_quiescence_proof_path(root)
      proof_before = File.binread(proof_path)

      fingerprint = convert_to_supported_quiescence_revision(path)
      assert_equal "process-custody-v1",
                   Hive::RuntimeControlPlane::QuiescenceUpgrade::QUIESCENCE_SCHEMA_REVISIONS
                     .fetch(fingerprint)
      skewed_before_resume = File.binread(path)

      output, _errors, process = run_hive(
        env, "daemon", "resume", "--timeout", "2", "--json"
      )
      assert_equal Hive::ExitCodes::CONFIG, process.exitstatus
      refused = JSON.parse(output)
      assert_equal "migration_required", refused.fetch("error_kind")
      assert_match(/current-format-migration/, refused.fetch("next_action"))
      assert_equal proof_before, File.binread(proof_path)
      assert_equal skewed_before_resume, File.binread(path),
                   "ordinary resume must not mutate skewed closed storage"
      closed = quiescence_upgrade_source(path).fetch(:lifecycle)
      assert_equal "paused", closed.fetch(:phase)
      assert_equal generation, closed.fetch(:generation)

      crashing_upgrade = Class.new(Hive::RuntimeControlPlane::QuiescenceUpgrade) do
        private

        def invalidate_proof!
          super
          raise IOError, "injected crash after proof invalidation"
        end
      end
      assert_raises(IOError) do
        crashing_upgrade.new(
          state_home: root, timeout_sec: 2, ownership_verifier: -> { true }
        ).call
      end
      refute_path_exists proof_path
      assert_equal skewed_before_resume, File.binread(path),
                   "a crash after proof removal must leave closed storage unchanged"
      closed_after_crash = quiescence_upgrade_source(path).fetch(:lifecycle)
      assert_equal "paused", closed_after_crash.fetch(:phase)
      assert_equal generation, closed_after_crash.fetch(:generation)

      upgraded = Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
        state_home: root, timeout_sec: 2, ownership_verifier: -> { true }
      ).call

      assert_equal "quiescing", upgraded.dig("lifecycle", "phase")
      assert_equal generation, upgraded.dig("lifecycle", "generation")
      refute_path_exists proof_path
      preserved = runtime_records(path)
      assert_equal installation_id, preserved.fetch(:installation_id)
      assert_equal [ [ "historical-attempt", "terminal", "succeeded" ] ],
                   preserved.fetch(:attempts)
      assert_equal [ [ "historical-payload", "historical-attempt" ] ],
                   preserved.fetch(:payloads)
      assert_equal "quiescing", preserved.dig(:lifecycle, :phase)
      assert_equal generation, preserved.dig(:lifecycle, :generation)

      output, errors, process = run_hive(
        env, "daemon", "resume", "--timeout", "2", "--json"
      )
      assert_equal 0, process.exitstatus, errors
      resumed = JSON.parse(output)
      assert_equal true, resumed.fetch("resumed")
      assert_equal true, resumed.fetch("admission_reopened")
      assert_equal generation, resumed.fetch("generation")
      assert_equal [], resumed.fetch("services"),
                   "no managed service may be invented during restore"
      refute_path_exists proof_path

      reopened = runtime_records(path)
      assert_equal installation_id, reopened.fetch(:installation_id)
      assert_equal [ [ "historical-attempt", "terminal", "succeeded" ] ],
                   reopened.fetch(:attempts)
      assert_equal [ [ "historical-payload", "historical-attempt" ] ],
                   reopened.fetch(:payloads)
      assert_equal "running", reopened.dig(:lifecycle, :phase)
      assert_equal generation, reopened.dig(:lifecycle, :generation)
    ensure
      database&.disconnect
    end
  end

  private

  def coordinator(root, database, registry:)
    Hive::Daemon::Quiescence.new(
      state_home: root, database: database, registry: registry,
      custody: UNSUPPORTED_CUSTODY, timeout_sec: 1,
      boot_id_reader: -> { "integration-boot" }
    )
  end

  def registry_for(root, database)
    Hive::RuntimeControlPlane::ProcessRegistry.new(
      database: database, state_home: root, custody: UNSUPPORTED_CUSTODY
    )
  end

  def register_process(registry, pid, origin:, role:, attempt_id: nil,
                       service_identity: nil, proven_child_safe: false)
    reservation = registry.reserve!(
      origin: origin, role: role, attempt_id: attempt_id, timeout_sec: 1
    )
    registration = registry.register!(
      reservation.id, pid: pid, service_identity: service_identity,
      proven_child_safe: proven_child_safe
    )
    reservation.release_fence!
    { reservation: reservation, registration: registration }
  end

  def with_runtime_home
    with_tmp_dir do |root|
      Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      env = ENV.to_h.merge(
        "HIVE_HOME" => root, "HOME" => root,
        "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR)
      )
      yield root, env
    end
  end

  def with_runtime_database
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      yield root, database
    ensure
      database&.disconnect
    end
  end

  def run_hive(env, *argv)
    Open3.capture3(env, RbConfig.ruby, "-Ilib", HIVE_BIN, *argv)
  end

  def lifecycle_tuple(database)
    lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).current
    {
      phase: lifecycle.phase, generation: lifecycle.generation,
      revision: lifecycle.revision, mutation_sequence: lifecycle.mutation_sequence
    }
  end

  def lifecycle_from_home(root)
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(root)
    ).open!
    lifecycle_tuple(database)
  ensure
    database&.disconnect
  end

  def status_payload(root)
    report = Hive::Daemon::StatusReport.new(hive_home: root, environment: {})
    report.payload
  end

  def with_trapped_process(root, name)
    signal_path = File.join(root, "#{name}-signal")
    ready_path = File.join(root, "#{name}-ready")
    script = <<~'RUBY'
      trap("TERM") { File.write(ARGV.fetch(0), "TERM\n"); exit! 0 }
      File.write(ARGV.fetch(1), Process.pid.to_s)
      loop { sleep 1 }
    RUBY
    pid = Process.spawn(
      RbConfig.ruby, "-e", script, signal_path, ready_path,
      in: File::NULL, out: File::NULL, err: File::NULL
    )
    wait_for_path(ready_path)
    yield pid, signal_path
  ensure
    terminate_process(pid)
  end

  def spawn_detached_tree(root)
    descendant_path = File.join(root, "detached-descendant-pid")
    ready_path = File.join(root, "detached-root-ready")
    release_path = File.join(root, "detached-root-release")
    signal_path = File.join(root, "detached-descendant-signal")
    script = <<~'RUBY'
      descendant = fork do
        Process.setsid
        trap("TERM") { File.write(ARGV.fetch(3), "TERM\n"); exit! 0 }
        loop { sleep 1 }
      end
      File.write(ARGV.fetch(0), descendant.to_s)
      File.write(ARGV.fetch(1), Process.pid.to_s)
      sleep 0.01 until File.exist?(ARGV.fetch(2))
    RUBY
    root_pid = Process.spawn(
      RbConfig.ruby, "-e", script, descendant_path, ready_path, release_path, signal_path,
      in: File::NULL, out: File::NULL, err: File::NULL
    )
    wait_for_path(ready_path)
    wait_for_path(descendant_path)
    {
      root_pid: root_pid, descendant_pid: Integer(File.read(descendant_path)),
      release_path: release_path, signal_path: signal_path
    }
  end

  def insert_missing_owned_process(database, generation)
    now = Time.now.utc.iso8601(6)
    database.with_exclusive_writer(role: :controller, timeout_sec: 1) do |authority|
      database.transaction(authority: authority) do |db|
        db[:owned_processes].insert(
          process_id: "missing-before-resume", installation_id: db[:installations].get(:installation_id),
          origin: "daemon_child", role: "service", pid: 2_000_000_000,
          start_fingerprint: "missing-process", state: "running",
          proven_child_safe: 0, custody_mode: "unverified",
          custody_evidence_json: JSON.generate(
            "eligible" => false, "mode" => "unverified", "reason" => "fixture"
          ),
          unknown_reason: "quiesce_crashed", created_at: now, updated_at: now
        )
      end
    end
    assert_equal generation, lifecycle_tuple(database).fetch(:generation)
  end

  def seed_terminal_attempt_and_payload(database)
    now = Time.now.utc.iso8601(6)
    installation_id = database.installation_identity.fetch(:installation_id)
    database.transaction do |db|
      db[:projects].insert(
        project_id: "historical-project", installation_id: installation_id,
        registration_id: "historical-registration", name: "historical-demo",
        observed_path: "/tmp/historical-demo",
        state_root_path: "/tmp/historical-demo/.hive-state", active: 1,
        registered_at: now
      )
      db[:task_subjects].insert(
        task_id: "historical-task", project_id: "historical-project",
        workflow_id: "coding", task_slug: "historical-task",
        observed_path: "/tmp/historical-demo/historical-task",
        source_fingerprint: "historical-source", generation: 1,
        created_at: now, last_observed_at: now
      )
      db[:attempts].insert(
        attempt_id: "historical-attempt", project_id: "historical-project",
        task_id: "historical-task", subject_kind: "task_stage",
        subject_key: "4-execute", subject_json: "{}",
        task_generation: "historical-generation",
        ownership_generation: "historical-owner", state: "terminal",
        outcome: "succeeded", ended_at: now, lease_version: 0,
        retry_charge: 0, refunded: 0, source_fingerprint: "historical-source",
        details_json: "{}", project_name: "historical-demo",
        task_slug: "historical-task", accepted_date: "2026-09-25",
        created_at: now, accepted_at: now
      )
      db[:payload_references].insert(
        payload_id: "historical-payload", attempt_id: "historical-attempt",
        kind: "attempt_log", relative_path: "terminal/attempt.log",
        state: "open", created_at: now
      )
    end
    installation_id
  end

  def convert_to_supported_quiescence_revision(path)
    connection = Sequel.connect(adapter: "sqlite", database: path, max_connections: 1)
    connection.run("PRAGMA foreign_keys = OFF")
    rows = connection[:attempts].all
    sql = connection[:sqlite_master].where(type: "table", name: "attempts").get(:sql)
      .sub(", 'interrupted'", "")
    indexes = connection[:sqlite_master].where(type: "index", tbl_name: "attempts")
      .exclude(sql: nil).order(:name).select_map(:sql)
    connection.transaction do
      connection.drop_table(:attempts)
      connection.run(sql)
      connection[:attempts].multi_insert(rows) unless rows.empty?
      indexes.each { |statement| connection.run(statement) }
    end
    connection.run("PRAGMA foreign_keys = ON")
    quiescence_upgrade_source(path).fetch(:schema_fingerprint)
  ensure
    connection&.disconnect
  end

  def quiescence_upgrade_source(path)
    Hive::RuntimeControlPlane::Database.new(path: path).quiescence_upgrade_source
  end

  def runtime_records(path)
    database = Hive::RuntimeControlPlane::Database.new(path: path).open!
    database.read do |db|
      {
        installation_id: db[:installations].get(:installation_id),
        attempts: db[:attempts].order(:attempt_id)
          .select_map([ :attempt_id, :state, :outcome ]),
        payloads: db[:payload_references].order(:payload_id)
          .select_map([ :payload_id, :attempt_id ]),
        lifecycle: db[:runtime_lifecycle].first
      }
    end
  ensure
    database&.disconnect
  end

  def wait_for_path(path)
    Timeout.timeout(5) do
      sleep 0.01 until File.file?(path)
    end
  end

  def assert_process_alive(pid)
    Process.kill(0, pid)
    assert true
  rescue Errno::ESRCH
    flunk "expected process #{pid} to remain alive"
  end

  def terminate_process(pid)
    return unless pid
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
