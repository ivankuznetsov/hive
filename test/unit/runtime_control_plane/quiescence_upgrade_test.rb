require "test_helper"
require "hive/runtime_control_plane/quiescence_upgrade"

class RuntimeControlPlaneQuiescenceUpgradeTest < Minitest::Test
  include HiveTestHelper

  NOW = "2026-09-25T12:00:00.000000Z"

  def test_explicit_upgrade_preserves_identity_attempts_and_payload_references
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
      identity = seed_attempt_and_payload(database)
      database.disconnect
      convert_to_pinned_v1(path)
      File.write(Hive::Paths.runtime_quiescence_proof_path(root), "stale", perm: 0o600)

      result = Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
        state_home: root, ownership_verifier: -> { true }
      ).call

      assert_equal "quiescing", result.fetch("lifecycle").fetch("phase")
      refute_path_exists Hive::Paths.runtime_quiescence_proof_path(root)
      upgraded = Hive::RuntimeControlPlane::Database.new(path: path).open!
      observed = upgraded.read do |db|
        {
          identity: db[:installations].get(:installation_id),
          attempts: db[:attempts].select_map(:attempt_id),
          payloads: db[:payload_references].select_map([ :payload_id, :attempt_id ]),
          lifecycle: db[:runtime_lifecycle].first,
          foreign_keys: db.fetch("PRAGMA foreign_key_check").all
        }
      end
      assert_equal identity, observed.fetch(:identity)
      assert_equal [ "attempt-1" ], observed.fetch(:attempts)
      assert_equal [ [ "payload-1", "attempt-1" ] ], observed.fetch(:payloads)
      assert_equal "quiescing", observed.dig(:lifecycle, :phase)
      assert_empty observed.fetch(:foreign_keys)
      assert_equal Hive::RuntimeControlPlane::SCHEMA_VERSION, upgraded.diagnostics.schema_version
    ensure
      upgraded&.disconnect
      database&.disconnect
    end
  end

  def test_unknown_source_is_rejected_without_invalidating_proof
    with_tmp_dir do |root|
      Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!.disconnect
      proof = Hive::Paths.runtime_quiescence_proof_path(root)
      File.write(proof, "keep", perm: 0o600)

      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
          state_home: root, ownership_verifier: -> { true }
        ).call
      end
      assert_equal :unsupported_quiescence_upgrade_source, error.code
      assert_equal "keep", File.read(proof)
    end
  end

  def test_upgrade_requires_verified_stopped_ownership
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      Hive::RuntimeControlPlane::Database.new(path: path).migrate!.disconnect
      convert_to_pinned_v1(path)

      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
          state_home: root, ownership_verifier: -> { false }
        ).call
      end
      assert_equal :ownership_unverifiable, error.code
    end
  end

  private

  def seed_attempt_and_payload(database)
    identity = database.read { |db| db[:installations].get(:installation_id) }
    database.transaction do |db|
      db[:projects].insert(
        project_id: "project-1", installation_id: identity, registration_id: "registration-1",
        name: "demo", observed_path: "/tmp/demo", state_root_path: "/tmp/demo/.hive-state",
        active: 1, registered_at: NOW
      )
      db[:task_subjects].insert(
        task_id: "task-1", project_id: "project-1", workflow_id: "coding",
        task_slug: "task-1", observed_path: "/tmp/demo/task-1", source_fingerprint: "source",
        generation: 1, created_at: NOW, last_observed_at: NOW
      )
      db[:attempts].insert(
        attempt_id: "attempt-1", project_id: "project-1", task_id: "task-1",
        subject_kind: "task_stage", subject_key: "4-execute", subject_json: "{}",
        task_generation: "generation-1", ownership_generation: "owner-1", state: "running",
        lease_version: 0, retry_charge: 0, refunded: 0, source_fingerprint: "source",
        details_json: "{}", project_name: "demo", task_slug: "task-1",
        accepted_date: "2026-09-25", created_at: NOW, accepted_at: NOW
      )
      db[:payload_references].insert(
        payload_id: "payload-1", attempt_id: "attempt-1", kind: "attempt_log",
        relative_path: "open/task.log", state: "open", created_at: NOW
      )
    end
    identity
  end

  def convert_to_pinned_v1(path)
    database = Sequel.connect(adapter: "sqlite", database: path, max_connections: 1)
    database.run("PRAGMA foreign_keys = OFF")
    attempt_rows = database[:attempts].all
    attempt_sql = database[:sqlite_master].where(type: "table", name: "attempts").get(:sql)
      .sub(", 'interrupted'", "")
    attempt_indexes = database[:sqlite_master].where(type: "index", tbl_name: "attempts")
      .exclude(sql: nil).order(:name).select_map(:sql)
    database.transaction do
      database.drop_table(:attempts)
      database.run(attempt_sql)
      database[:attempts].multi_insert(attempt_rows) unless attempt_rows.empty?
      attempt_indexes.each { |sql| database.run(sql) }
    end
    %i[quiescence_cleanup_writes owned_processes launch_reservations runtime_lifecycle].each do |table|
      database.drop_table(table)
    end
    database[:schema_info].update(version: 1)
  ensure
    database&.disconnect
  end
end
