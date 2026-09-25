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

  def test_quiescence_schema_revisions_preserve_closed_generation_and_render_current_ddl
    revisions = [
      [
        "484dfc25ef94ab9c06867351308121ba2ce904f1e7f1ef6dc004f45b8d65e479",
        false, "paused"
      ],
      [
        "f31651456b27230ef802d910733887fcb5a64b65dead502a2752b1c183f592f3",
        true, "quiescing"
      ]
    ]

    revisions.each do |fingerprint, custody_columns, phase|
      with_tmp_dir do |root|
        assert_quiescence_revision_upgrade(
          root, fingerprint: fingerprint, custody_columns: custody_columns, phase: phase
        )
      end
    end
  end

  def test_quiescence_revision_requires_closed_lifecycle_without_invalidating_proof
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      Hive::RuntimeControlPlane::Database.new(path: path).migrate!.disconnect
      convert_to_quiescence_revision(path, custody_columns: true)
      proof = Hive::Paths.runtime_quiescence_proof_path(root)
      File.write(proof, "keep", perm: 0o600)

      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
          state_home: root, ownership_verifier: -> { true }
        ).call
      end

      assert_equal :quiescence_upgrade_requires_closed_lifecycle, error.code
      assert_equal "keep", File.read(proof)
      source = Hive::RuntimeControlPlane::Database.new(path: path).quiescence_upgrade_source
      assert_equal "running", source.dig(:lifecycle, :phase)
      assert_equal 0, source.dig(:lifecycle, :generation)
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

  def assert_quiescence_revision_upgrade(root, fingerprint:, custody_columns:, phase:)
    path = Hive::Paths.runtime_control_plane_path(root)
    database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
    identity = seed_attempt_and_payload(database)
    seed_closed_lifecycle(database, phase: phase)
    database.disconnect
    convert_to_quiescence_revision(path, custody_columns: custody_columns)
    source = Hive::RuntimeControlPlane::Database.new(path: path).quiescence_upgrade_source
    assert_equal fingerprint, source.fetch(:schema_fingerprint)
    assert_equal phase, source.dig(:lifecycle, :phase)
    proof = Hive::Paths.runtime_quiescence_proof_path(root)
    File.write(proof, "stale", perm: 0o600)

    result = Hive::RuntimeControlPlane::QuiescenceUpgrade.new(
      state_home: root, ownership_verifier: -> { true }, clock: -> { Time.iso8601(NOW) }
    ).call

    assert_equal "quiescing", result.dig("lifecycle", "phase")
    assert_equal 7, result.dig("lifecycle", "generation")
    refute_path_exists proof
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
    assert_equal 7, observed.dig(:lifecycle, :generation)
    assert_equal 12, observed.dig(:lifecycle, :revision)
    assert_equal 24, observed.dig(:lifecycle, :mutation_sequence)
    assert_equal "boot-7", observed.dig(:lifecycle, :boot_id)
    assert_in_delta 9876.5, observed.dig(:lifecycle, :deadline_monotonic)
    assert_in_delta 24.25, observed.dig(:lifecycle, :shutdown_grace_sec)
    assert_equal '["attempt-1"]', observed.dig(:lifecycle, :interrupted_attempt_ids_json)
    assert_nil observed.dig(:lifecycle, :paused_at)
    assert_empty observed.fetch(:foreign_keys)
    assert_equal Hive::RuntimeControlPlane::EXPECTED_SCHEMA_SHA256,
                 upgraded.quiescence_upgrade_source.fetch(:schema_fingerprint)
    assert_equal current_schema_rows, schema_rows(path)
  ensure
    upgraded&.disconnect
    database&.disconnect
  end

  def seed_closed_lifecycle(database, phase:)
    database.controller_transaction do |db|
      db[:runtime_lifecycle].update(
        phase: phase, generation: 7, revision: 11, mutation_sequence: 23,
        boot_id: "boot-7", deadline_monotonic: 9876.5, shutdown_grace_sec: 24.25,
        interrupted_attempt_ids_json: '["attempt-1"]', quiesce_started_at: NOW,
        paused_at: phase == "paused" ? NOW : nil, updated_at: NOW
      )
    end
  end

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

  def convert_to_quiescence_revision(path, custody_columns:)
    database = Sequel.connect(adapter: "sqlite", database: path, max_connections: 1)
    database.run("PRAGMA foreign_keys = OFF")
    rebuild_table(database, :attempts) { |sql| sql.sub(", 'interrupted'", "") }
    unless custody_columns
      rebuild_table(database, :owned_processes, removed_columns: %i[custody_path custody_evidence_json]) do |sql|
        sql.sub(", `custody_path` varchar(255), `custody_evidence_json` text", "")
      end
    end
    database.run("PRAGMA foreign_keys = ON")
  ensure
    database&.disconnect
  end

  def rebuild_table(database, table, removed_columns: [])
    rows = database[table].all.map { |row| row.reject { |column, _| removed_columns.include?(column) } }
    sql = database[:sqlite_master].where(type: "table", name: table.to_s).get(:sql)
    sql = yield(sql)
    indexes = database[:sqlite_master].where(type: "index", tbl_name: table.to_s)
      .exclude(sql: nil).order(:name).select_map(:sql)
    database.transaction do
      database.drop_table(table)
      database.run(sql)
      database[table].multi_insert(rows) unless rows.empty?
      indexes.each { |statement| database.run(statement) }
    end
  end

  def current_schema_rows
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      Hive::RuntimeControlPlane::Database.new(path: path).migrate!.disconnect
      return schema_rows(path)
    end
  end

  def schema_rows(path)
    database = Sequel.connect(adapter: "sqlite", database: path, readonly: true, max_connections: 1)
    database[:sqlite_master].where(type: %w[table index])
      .exclude(name: "schema_info").exclude(Sequel.like(:name, "sqlite_%"))
      .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
  ensure
    database&.disconnect
  end
end
