require "test_helper"
require "hive/runtime_control_plane"

class RuntimeControlPlaneSchemaTest < Minitest::Test
  include HiveTestHelper

  EXPECTED_TABLES = %i[
    attempt_accounting
    attempt_relationships
    attempts
    capacity_reservations
    daemon_runtime
    dispatch_outbox
    dispatch_requests
    installations
    maintenance_checkpoints
    patrol_allowances
    payload_references
    pr_merge_reconciliations
    projections
    projects
    provider_audit
    provider_circuits
    routing_policies
    schema_info
    task_counters
    task_leases
    task_subjects
    terminal_pending_publications
    token_usage
  ].freeze

  def test_migration_creates_the_complete_domain_schema
    with_database do |database|
      tables = database.read { |connection| connection.tables.sort }

      assert_equal EXPECTED_TABLES, tables
      assert_equal Hive::RuntimeControlPlane::EXPECTED_TABLES.sort,
                   (tables - [ :schema_info ]).sort
    end
  end

  def test_foreign_keys_and_checks_reject_invalid_domain_rows
    with_database do |database|
      error = assert_raises(Sequel::ForeignKeyConstraintViolation) do
        database.transaction do |connection|
          connection[:projects].insert(
            project_id: uuid("1"), installation_id: uuid("9"),
            registration_id: uuid("2"), name: "missing-installation",
            observed_path: "/tmp/missing", state_root_path: "/tmp/missing/.hive-state",
            active: 1, registered_at: timestamp
          )
        end
      end
      assert_match(/foreign key/i, error.message)

      assert_raises(Sequel::CheckConstraintViolation) do
        database.transaction do |connection|
          connection[:dispatch_requests].insert(
            request_id: uuid("3"), project_id: project_id(database),
            task_id: nil, subject_kind: "task_stage", subject_key: "build",
            task_generation: -1, intended_stage: "4-execute", state: "queued",
            priority: 0, payload_json: "{}", created_at: timestamp, updated_at: timestamp
          )
        end
      end
    end
  end

  def test_partial_unique_indexes_protect_active_attempt_probe_and_idempotency_identity
    with_database do |database|
      ids = seed_project_and_task(database)
      database.transaction do |connection|
        base = {
          task_id: ids.fetch(:task_id), subject_kind: "task_stage", subject_key: "4-execute",
          task_generation: 1, ownership_generation: 1, state: "running", lease_version: 0,
          routing_json: "{}", created_at: timestamp
        }
        connection[:attempts].insert(base.merge(attempt_id: uuid("4")))
        assert_raises(Sequel::UniqueConstraintViolation) do
          connection[:attempts].insert(base.merge(attempt_id: uuid("5")))
        end
      end

      database.transaction do |connection|
        circuit = {
          circuit_id: uuid("6"), scope_kind: "provider", provider_account_id: "acct",
          model: "", automatic_state: "closed", manual_block: 0,
          generation: 0, journal_epoch: uuid("7"), probe_attempt_id: uuid("4"),
          updated_at: timestamp
        }
        connection[:provider_circuits].insert(circuit)
        assert_raises(Sequel::UniqueConstraintViolation) do
          connection[:provider_circuits].insert(
            circuit.merge(circuit_id: uuid("8"), provider_account_id: "other")
          )
        end
      end

      database.transaction do |connection|
        request = {
          project_id: ids.fetch(:project_id), task_id: ids.fetch(:task_id),
          subject_kind: "task_stage", subject_key: "4-execute", task_generation: 2,
          intended_stage: "4-execute", state: "queued", priority: 0,
          idempotency_key: "same", payload_json: "{}", created_at: timestamp,
          updated_at: timestamp
        }
        connection[:dispatch_requests].insert(request.merge(request_id: uuid("9")))
        assert_raises(Sequel::UniqueConstraintViolation) do
          connection[:dispatch_requests].insert(request.merge(request_id: uuid("a")))
        end
      end
    end
  end

  def test_open_payloads_have_no_final_digest_and_sealed_payloads_require_one
    with_database do |database|
      ids = seed_project_and_task(database)
      base = {
        task_id: ids.fetch(:task_id), kind: "attempt-log",
        created_at: timestamp
      }

      database.transaction do |connection|
        connection[:payload_references].insert(
          base.merge(
            payload_id: uuid("3"), relative_path: "open/task.log", state: "open"
          )
        )
      end

      assert_raises(Sequel::CheckConstraintViolation) do
        database.transaction do |connection|
          connection[:payload_references].insert(
            base.merge(
              payload_id: uuid("4"), relative_path: "sealed/missing.log", state: "sealed"
            )
          )
        end
      end

      database.transaction do |connection|
        connection[:payload_references].insert(
          base.merge(
            payload_id: uuid("5"), relative_path: "sealed/final.log", state: "sealed",
            sha256: "a" * 64, bytes: 12
          )
        )
      end
    end
  end

  def test_canonical_codec_round_trips_json_and_utc_microseconds
    codec = Hive::RuntimeControlPlane::Codec
    value = {
      "z" => [ nil, true, "Cafe\u0301", { "\u03b2" => 2 } ],
      :a => { c: 3, b: 2 }
    }

    encoded = codec.dump_json(value)
    assert_equal "{\"a\":{\"b\":2,\"c\":3},\"z\":[null,true,\"Café\",{\"β\":2}]}", encoded
    assert_equal JSON.parse(encoded), codec.load_json(encoded)
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      codec.load_json("{\"z\":1,\"a\":2}")
    end

    local = Time.new(2026, 10, 25, 1, 30, Rational(123_456, 1_000_000), "+01:00")
    dumped = codec.dump_time(local)
    assert_equal "2026-10-25T00:30:00.123456Z", dumped
    loaded = codec.load_time(dumped)
    assert_equal local.utc, loaded
    assert_equal 123_456, loaded.usec
  end

  def test_identity_adapter_preserves_project_ids_and_rejects_aliases
    identity = Hive::RuntimeControlPlane::Identity.new(uuid_generator: -> { uuid("f") })
    original = project_entry(path: "/old/path")
    moved = project_entry(path: "/new/path")

    assert_equal identity.project(original).project_id, identity.project(moved).project_id
    assert_equal "/new/path", identity.project(moved).observed_path
    legacy = original.merge("registration_id" => "legacy:#{original.fetch('project_id')}")
    assert_equal legacy.fetch("registration_id"), identity.project(legacy).registration_id

    duplicate = project_entry(
      project_id: original.fetch("project_id"), registration_id: uuid("d"),
      path: "/clone/path"
    )
    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      identity.validate_projects!([ original, duplicate ])
    end
    assert_equal :project_identity_collision, error.code

    alias_entry = project_entry(
      project_id: uuid("c"), registration_id: uuid("b"), path: "/different",
      hive_state_path: original.fetch("hive_state_path")
    )
    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      identity.validate_projects!([ original, alias_entry ])
    end
    assert_equal :state_root_collision, error.code

    subject = identity.task_subject(
      project_id: original.fetch("project_id"), workflow_id: "coding", task_slug: "task-a"
    )
    assert_equal uuid("f"), subject.task_id
    assert_equal subject.task_id, identity.task_subject(
      project_id: original.fetch("project_id"), workflow_id: "coding", task_slug: "task-a",
      task_id: subject.task_id
    ).task_id

    assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      identity.validate_task_subjects!([
        subject,
        identity.task_subject(
          project_id: original.fetch("project_id"), workflow_id: "coding", task_slug: "task-b",
          task_id: subject.task_id
        )
      ])
    end
  end

  private

  def with_database
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "runtime.sqlite3")
      )
      database.migrate!
      yield database
    ensure
      database&.disconnect
    end
  end

  def seed_project_and_task(database)
    installation_id = database.read do |connection|
      connection[:installations].get(:installation_id)
    end
    project_id = uuid("1")
    task_id = "task-260829-0001"
    database.transaction do |connection|
      connection[:projects].insert(
        project_id: project_id, installation_id: installation_id,
        registration_id: uuid("2"), name: "hive", observed_path: "/tmp/hive",
        state_root_path: "/tmp/hive/.hive-state", active: 1, registered_at: timestamp
      )
      connection[:task_subjects].insert(
        task_id: task_id, project_id: project_id, workflow_id: "coding",
        task_slug: "sqlite", observed_path: "/tmp/hive/.hive-state/stages/4-execute/sqlite",
        generation: 1, created_at: timestamp, last_observed_at: timestamp
      )
    end
    { project_id: project_id, task_id: task_id }
  end

  def project_id(database)
    installation_id = database.read { |connection| connection[:installations].get(:installation_id) }
    id = uuid("1")
    database.transaction do |connection|
      connection[:projects].insert(
        project_id: id, installation_id: installation_id, registration_id: uuid("2"),
        name: "hive", observed_path: "/tmp/hive", state_root_path: "/tmp/hive/.hive-state",
        active: 1, registered_at: timestamp
      )
    end
    id
  end

  def project_entry(project_id: uuid("1"), registration_id: uuid("2"), path:,
                    hive_state_path: nil)
    {
      "name" => "hive", "path" => path,
      "hive_state_path" => hive_state_path || File.join(path, ".hive-state"),
      "project_id" => project_id, "registration_id" => registration_id,
      "registered_at" => timestamp
    }
  end

  def timestamp
    "2026-08-29T12:00:00.123456Z"
  end

  def uuid(hex)
    "#{hex * 8}-#{hex * 4}-4#{hex * 3}-a#{hex * 3}-#{hex * 12}"
  end
end
