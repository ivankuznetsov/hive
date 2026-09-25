require "test_helper"
require "timeout"
require "hive/daemon/quiescence"
require "hive/runtime_control_plane/process_registry"

class DaemonQuiescenceCoordinatorIntegrationTest < Minitest::Test
  include HiveTestHelper

  def test_real_registered_process_is_stopped_before_checkpoint_and_proof
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root
      )
      child = Process.spawn(
        "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done",
        in: File::NULL, out: File::NULL, err: File::NULL
      )
      reaper = Thread.new { Process.wait(child) rescue Errno::ECHILD }
      wait_until_alive(child)
      reservation = registry.reserve!(origin: "safe_fixture", role: "fixture")
      registry.register!(reservation.id, pid: child, proven_child_safe: true)
      reservation.release_fence!
      capability = Object.new
      capability.define_singleton_method(:call) do
        Hive::RuntimeControlPlane::CapabilityVerdict.new(
          eligible: true, reason: nil, ownership_mode: "registered_only",
          disqualifying_inventory: []
        )
      end

      result = Hive::Daemon::Quiescence.new(
        state_home: root, database: database, registry: registry,
        capability: capability, timeout_sec: 1,
        boot_id_reader: -> { "integration-boot" }
      ).call

      assert result.paused, result.to_h.inspect
      assert reaper.join(1), "quiesced fixture process was not reaped"
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
      database.open!
      assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
      assert File.file?(Hive::Paths.runtime_quiescence_proof_path(root))
    ensure
      reservation&.release_fence!
      begin
        Process.kill("KILL", child) if child
      rescue Errno::ESRCH
        nil
      end
      reaper&.join(1)
      database&.disconnect
    end
  end

  private

  def wait_until_alive(pid)
    Timeout.timeout(2) do
      loop do
        Process.kill(0, pid)
        break
      rescue Errno::ESRCH
        sleep 0.01
      end
    end
  end
end
