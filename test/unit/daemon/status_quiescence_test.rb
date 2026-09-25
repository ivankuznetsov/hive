require "test_helper"
require "hive/daemon/quiescence"
require "hive/daemon/status_report"
require "json_schemer"

class HiveDaemonStatusQuiescenceTest < Minitest::Test
  include HiveTestHelper

  class EligibleCapability
    def call
      Hive::RuntimeControlPlane::CapabilityVerdict.new(
        eligible: true, reason: nil, ownership_mode: "registered_only",
        disqualifying_inventory: []
      )
    end
  end

  class FixedProcessIdentity
    def initialize(status: nil, error: nil, snapshot: nil)
      @status = status
      @error = error
      @snapshot = snapshot
    end

    def status(_identity)
      raise @error if @error

      @status
    end

    def capture(_pid) = @snapshot
  end

  def test_status_reports_paused_only_while_proof_and_liveness_remain_valid
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      result = Hive::Daemon::Quiescence.new(
        state_home: root, database: database, capability: EligibleCapability.new,
        timeout_sec: 1, boot_id_reader: -> { "boot-test" }
      ).call
      assert result.paused
      database.disconnect

      report = Hive::Daemon::StatusReport.new(hive_home: root, environment: {})
      stub_non_service_fields(report)
      payload = report.payload

      assert_equal "active", payload.dig("runtime_installation", "phase")
      assert_equal "paused", payload.dig("lifecycle", "phase")
      assert_equal result.generation, payload.dig("lifecycle", "generation")
      assert_equal true, payload.dig("lifecycle", "proof", "valid")
      assert_equal true, payload.dig("lifecycle", "liveness", "clear")
      assert_equal true, payload.dig("quiescence_capability", "eligible")
      assert_status_schema(payload)

      File.write(Hive::Paths.runtime_quiescence_proof_path(root), "{}\n", perm: 0o600)
      downgraded = report.payload
      assert_equal "paused", downgraded.dig("lifecycle", "durable_phase")
      assert_equal "quiescing", downgraded.dig("lifecycle", "phase")
      assert_equal false, downgraded.dig("lifecycle", "proof", "valid")
      assert_status_schema(downgraded)
    ensure
      database&.disconnect
    end
  end

  def test_status_on_schema_skew_is_read_only_and_reports_unknown_capability
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      database.transaction { |db| db[:schema_info].update(version: 0) }
      database.disconnect
      before = File.binread(Hive::Paths.runtime_control_plane_path(root))

      report = Hive::Daemon::StatusReport.new(hive_home: root, environment: {})
      stub_non_service_fields(report)
      payload = report.payload

      assert_equal "older_schema", payload.dig("runtime_installation", "database_status")
      assert_equal false, payload.dig("quiescence_capability", "eligible")
      assert_equal "schema_older_schema", payload.dig("quiescence_capability", "reason")
      assert_equal before, File.binread(Hive::Paths.runtime_control_plane_path(root))
      assert_status_schema(payload)
    ensure
      database&.disconnect
    end
  end

  def test_status_without_a_daemon_or_runtime_is_read_only
    with_tmp_dir do |root|
      report = Hive::Daemon::StatusReport.new(hive_home: root, environment: {})
      stub_non_service_fields(report)

      payload = report.payload

      assert_equal false, payload.fetch("running")
      assert_equal "absent", payload.dig("runtime_installation", "phase")
      assert_equal "unknown", payload.dig("lifecycle", "phase")
      assert_equal "runtime_absent", payload.dig("quiescence_capability", "reason")
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
      assert_status_schema(payload)
    end
  end

  def test_status_capability_rejects_an_unproven_registered_surface
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      insert_registered_process(database, proven_child_safe: false)
      database.disconnect
      report = Hive::Daemon::StatusReport.new(hive_home: root, environment: {})
      stub_non_service_fields(report)

      payload = report.payload

      assert_equal false, payload.dig("quiescence_capability", "eligible")
      assert_equal "unproven_launch_surface", payload.dig("quiescence_capability", "reason")
      assert_equal "running", payload.dig("lifecycle", "phase")
      assert_status_schema(payload)
    ensure
      database&.disconnect
    end
  end

  def test_paused_status_downgrades_for_alive_ambiguous_and_unprobeable_proof_inventory
    cases = {
      matching: "owned_process_alive",
      unverifiable: "process_identity_unverifiable",
      permission: "probe_failed:Errno::EPERM"
    }
    cases.each do |name, reason|
      with_paused_proof_inventory do |root|
        identity = if name == :permission
          FixedProcessIdentity.new(error: Errno::EPERM.new("denied"))
        else
          FixedProcessIdentity.new(status: name)
        end
        report = Hive::Daemon::StatusReport.new(
          hive_home: root, environment: {}, process_identity: identity
        )
        stub_non_service_fields(report)

        payload = report.payload

        assert_equal "quiescing", payload.dig("lifecycle", "phase"), name
        assert_equal false, payload.dig("lifecycle", "liveness", "clear"), name
        assert_equal reason,
                     payload.dig("lifecycle", "liveness", "remaining", 0, "unknown_reason"), name
        assert_status_schema(payload)
      end
    end
  end

  def test_paused_status_downgrades_when_liveness_probe_deadline_is_exhausted
    with_paused_proof_inventory do |root|
      report = Hive::Daemon::StatusReport.new(
        hive_home: root, environment: {},
        process_identity: FixedProcessIdentity.new(status: :missing),
        liveness_timeout_sec: 0
      )
      stub_non_service_fields(report)

      payload = report.payload

      assert_equal "quiescing", payload.dig("lifecycle", "phase")
      assert_equal "probe_deadline",
                   payload.dig("lifecycle", "liveness", "remaining", 0, "unknown_reason")
      assert_status_schema(payload)
    end
  end

  def test_post_proof_daemon_respawn_downgrades_without_a_database_write
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      result = Hive::Daemon::Quiescence.new(
        state_home: root, database: database, capability: EligibleCapability.new,
        timeout_sec: 1, boot_id_reader: -> { "boot-test" }
      ).call
      assert result.paused
      database.open!
      before = database.read { |db| db[:runtime_lifecycle].get(:mutation_sequence) }
      database.disconnect
      File.write(
        File.join(root, ".daemon.pid"),
        { "pid" => 123_456, "process_start_time" => "respawn-start" }.to_yaml,
        perm: 0o600
      )
      snapshot = Hive::Attempts::ProcessSnapshot.new(
        pid: 123_456, start_fingerprint: "respawn-start",
        session_id: 123_456, process_group_id: 123_456
      )
      report = Hive::Daemon::StatusReport.new(
        hive_home: root, environment: {},
        process_identity: FixedProcessIdentity.new(snapshot: snapshot)
      )
      stub_non_service_fields(report)

      payload = report.payload

      assert_equal "quiescing", payload.dig("lifecycle", "phase")
      assert_equal "legacy_process_unregistered", payload.dig("quiescence_capability", "reason")
      after = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).quiescence_status_snapshot.dig(:lifecycle, :mutation_sequence)
      assert_equal before, after
      assert_status_schema(payload)
    ensure
      database&.disconnect
    end
  end

  private

  def stub_non_service_fields(report)
    report.define_singleton_method(:probe_service_state) do
      {
        "service_installed" => false, "service_enabled" => false,
        "unit_path" => nil, "installed_binary" => nil, "expected_binary" => nil
      }
    end
    report.define_singleton_method(:update_nudge_payload) { nil }
  end

  def with_paused_proof_inventory
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      result = Hive::Daemon::Quiescence.new(
        state_home: root, database: database, capability: EligibleCapability.new,
        timeout_sec: 1, boot_id_reader: -> { "boot-test" }
      ).call
      assert result.paused
      database.disconnect
      path = Hive::Paths.runtime_quiescence_proof_path(root)
      proof = JSON.parse(File.binread(path))
      proof["inventory"] = [
        {
          "pid" => 123_456, "start_fingerprint" => "fixture-start",
          "service_identity" => "hive-web", "origin" => "safe_fixture",
          "role" => "service", "state" => "stopped"
        }
      ]
      File.write(path, "#{JSON.generate(proof)}\n", perm: 0o600)
      yield root
    ensure
      database&.disconnect
    end
  end

  def insert_registered_process(database, proven_child_safe:)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      db[:owned_processes].insert(
        process_id: "registered-service", installation_id: db[:installations].get(:installation_id),
        service_identity: "hive-web", origin: "unknown_fixture", role: "service",
        pid: 123_456, start_fingerprint: "fixture-start", state: "running",
        proven_child_safe: proven_child_safe ? 1 : 0, custody_mode: "unverified",
        created_at: now, updated_at: now
      )
    end
  end

  def assert_status_schema(payload)
    schema = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-status")))
    )
    assert_empty schema.validate(payload).map { |error| error["error"] }
  end
end
