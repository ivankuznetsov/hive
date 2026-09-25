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
