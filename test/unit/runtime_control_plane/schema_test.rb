require "test_helper"
require "hive/runtime_control_plane"

class RuntimeControlPlaneSchemaTest < Minitest::Test
  include HiveTestHelper

  EXPECTED_TABLES = %i[
    attempt_failure_cohorts
    attempts
    daemon_runtime
    dispatch_requests
    installations
    payload_references
    pr_merge_project_state
    pr_merge_reconciliations
    projects
    schema_info
    task_counters
    task_leases
    task_subjects
    token_usage
  ].freeze

  EXPECTED_ATTEMPT_COLUMNS = %i[
    accepted_at accepted_date admission_runtime_digest admission_stage
    admission_utc_date admission_workflow attempt_id created_at ended_at
    failure_cohort_counted failure_cohort_date failure_cohort_identity_digest
    failure_cohort_occurred_at failure_cohort_outcome heartbeat_at lease_version
    lost_recovery_cleanup lost_recovery_phase lost_recovery_request_id
    lost_recovery_revision lost_recovery_updated_at outcome ownership_generation
    project_id project_name provider_account_id publication_accounting_acknowledged
    publication_dispatch_acknowledged publication_journal_acknowledged publication_promoted record_digest
    record_json refunded request_id retain_until retry_charge source_fingerprint
    started_at state subject_json subject_key subject_kind task_generation task_id
    task_slug terminal_publication_created_at terminal_receipt_digest
    terminal_receipt_json terminal_task_source_fingerprint
  ].freeze

  EXPECTED_DISPATCH_COLUMNS = %i[
    claim_attempt_id claim_owner claim_pid claim_process_identity claimed_at
    created_at due_at idempotency_key intended_stage payload_json priority
    project_id recovery_request request_id result_available_at result_delivered_at
    result_digest result_json result_state retain_until revision source_fingerprint
    state subject_key subject_kind task_generation task_id task_slug updated_at
  ].freeze

  RETIRED_ATTEMPT_COLUMNS = %i[
    checkpoint_json owner_identity_json routing_json
  ].freeze

  def test_migration_creates_the_complete_domain_schema
    with_database do |database|
      tables, attempt_columns, dispatch_columns = database.read do |connection|
        [
          connection.tables.sort,
          connection.schema(:attempts).map(&:first).sort,
          connection.schema(:dispatch_requests).map(&:first).sort
        ]
      end

      assert_equal EXPECTED_TABLES, tables
      assert_equal EXPECTED_ATTEMPT_COLUMNS, attempt_columns
      assert_equal EXPECTED_DISPATCH_COLUMNS, dispatch_columns
      assert_empty RETIRED_ATTEMPT_COLUMNS & attempt_columns
      refute_includes dispatch_columns, :routing_policy_digest
    end
  end

  def test_every_retained_foreign_key_has_a_full_leading_index
    with_database do |database|
      missing = database.read do |connection|
        EXPECTED_TABLES.flat_map do |table|
          next [] if table == :schema_info

          indexes = full_index_columns(connection, table)
          connection.foreign_key_list(table).filter_map do |foreign_key|
            columns = foreign_key.fetch(:columns).map(&:to_s)
            next if indexes.any? { |index| index.first(columns.length) == columns }

            "#{table}(#{columns.join(',')})"
          end
        end
      end

      assert_empty missing, "foreign-key child paths without leading indexes: #{missing.join(', ')}"
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
            task_slug: "build",
            task_generation: "opaque", intended_stage: "4-execute", state: "queued",
            priority: -1, source_fingerprint: "sha256:source", payload_json: "{}",
            created_at: timestamp, updated_at: timestamp
          )
        end
      end
    end
  end

  def test_partial_indexes_protect_active_attempt_and_idempotency_identity
    with_database do |database|
      ids = seed_project_and_task(database)
      database.transaction do |connection|
        base = attempt_row(ids)
        connection[:attempts].insert(base.merge(attempt_id: uuid("4")))
        assert_raises(Sequel::UniqueConstraintViolation) do
          connection[:attempts].insert(base.merge(attempt_id: uuid("5")))
        end
      end

      foreign_keys = database.read do |connection|
        {
          cohort: connection.foreign_key_list(:attempt_failure_cohorts).first,
          attempt: connection.foreign_key_list(:attempts).find do |foreign_key|
            foreign_key.fetch(:columns) == [ :request_id ]
          end
        }
      end
      assert_equal :set_null,
                   foreign_keys.dig(:cohort, :on_delete)
      assert_equal :set_null, foreign_keys.dig(:attempt, :on_delete)

      database.transaction do |connection|
        request = {
          project_id: ids.fetch(:project_id), task_id: ids.fetch(:task_id),
          subject_kind: "task_stage", subject_key: "4-execute", task_slug: "sqlite",
          task_generation: 2,
          intended_stage: "4-execute", state: "queued", priority: 0,
          idempotency_key: "same", source_fingerprint: "sha256:request-source",
          payload_json: "{}", created_at: timestamp, updated_at: timestamp
        }
        connection[:dispatch_requests].insert(request.merge(request_id: uuid("9")))
        assert_raises(Sequel::UniqueConstraintViolation) do
          connection[:dispatch_requests].insert(request.merge(request_id: uuid("a")))
        end
      end
    end
  end

  def test_retained_enums_accept_emitted_values_and_reject_retired_values
    with_database do |database|
      ids = seed_project_and_task(database)
      request = dispatch_row(ids)
      database.transaction do |connection|
        connection[:dispatch_requests].insert(request)
        %w[claimed admitted awaiting_delivery completed cancelled].each do |state|
          connection[:dispatch_requests].where(request_id: request.fetch(:request_id)).update(state: state)
        end
      end

      installation = database.read { |connection| connection[:installations].get(:installation_id) }
      database.transaction do |connection|
        %w[starting running stopped unavailable].each_with_index do |state, index|
          connection[:daemon_runtime].insert(
            installation_id: installation, daemon_kind: "daemon-#{index}", state: state,
            observed_at: timestamp, generation: 0
          )
        end
        assert_raises(Sequel::CheckConstraintViolation) do
          connection[:daemon_runtime].insert(
            installation_id: installation, daemon_kind: "retired", state: "stopping",
            observed_at: timestamp, generation: 0
          )
        end
      end

      database.transaction do |connection|
        connection[:payload_references].insert(
          payload_id: uuid("3"), task_id: ids.fetch(:task_id), kind: "attempt_log",
          relative_path: "open/task.log", state: "open", created_at: timestamp
        )
        connection[:payload_references].insert(
          payload_id: uuid("4"), task_id: ids.fetch(:task_id), kind: "attempt_log",
          relative_path: "sealed/task.log", sha256: "a" * 64, bytes: 12,
          state: "sealed", created_at: timestamp
        )
        connection[:payload_references].insert(
          payload_id: uuid("5"), task_id: ids.fetch(:task_id), kind: "attempt_log",
          relative_path: "sealed/expired.log", sha256: "b" * 64, bytes: 13,
          state: "releasable", created_at: timestamp, retain_until: timestamp
        )
        assert_raises(Sequel::CheckConstraintViolation) do
          connection[:payload_references].insert(
            payload_id: uuid("6"), task_id: ids.fetch(:task_id), kind: "attempt_log",
            relative_path: "sealed/pinned.log", sha256: "c" * 64, bytes: 14,
            state: "pinned", created_at: timestamp
          )
        end
      end
    end
  end

  def test_attempt_result_and_publication_checks_reject_invalid_combinations
    with_database do |database|
      ids = seed_project_and_task(database)

      assert_raises(Sequel::CheckConstraintViolation) do
        database.transaction do |connection|
          connection[:attempts].insert(
            attempt_row(ids).merge(
              attempt_id: uuid("4"), state: "terminal", outcome: "succeeded",
              ended_at: timestamp, terminal_receipt_json: "{}"
            )
          )
        end
      end

      assert_raises(Sequel::CheckConstraintViolation) do
        database.transaction do |connection|
          connection[:attempts].insert(
            attempt_row(ids).merge(
              attempt_id: uuid("5"), state: "lost", ended_at: timestamp,
              terminal_receipt_json: "{}", terminal_receipt_digest: "a" * 64,
              terminal_publication_created_at: timestamp,
              lost_recovery_phase: "complete", lost_recovery_revision: 1,
              lost_recovery_updated_at: timestamp
            )
          )
        end
      end

      assert_raises(Sequel::CheckConstraintViolation) do
        database.transaction do |connection|
          connection[:dispatch_requests].insert(
            dispatch_row(ids).merge(
              request_id: uuid("6"), result_state: "pending", result_json: "{}",
              result_digest: "a" * 64, result_available_at: timestamp,
              result_delivered_at: timestamp, retain_until: timestamp
            )
          )
        end
      end

      assert_raises(Sequel::CheckConstraintViolation) do
        database.transaction do |connection|
          connection[:attempts].insert(
            attempt_row(ids).merge(
              attempt_id: uuid("7"), state: "terminal", outcome: "failed",
              ended_at: timestamp, terminal_receipt_json: "{}",
              terminal_receipt_digest: "a" * 64,
              terminal_task_source_fingerprint: "sha256:source",
              terminal_publication_created_at: timestamp,
              failure_cohort_date: "2026-08-29",
              failure_cohort_identity_digest: "b" * 64,
              failure_cohort_outcome: "failed", failure_cohort_occurred_at: timestamp,
              failure_cohort_counted: 0
            )
          )
        end
      end

      database.transaction do |connection|
        connection[:attempts].insert(
          attempt_row(ids).merge(
            attempt_id: uuid("8"), subject_key: "terminal-proof", state: "terminal",
            outcome: "succeeded", ended_at: timestamp, terminal_receipt_json: "{}",
            terminal_receipt_digest: "c" * 64,
            terminal_task_source_fingerprint: "sha256:source",
            terminal_publication_created_at: timestamp,
            publication_journal_acknowledged: 1,
            publication_accounting_acknowledged: 1,
            publication_dispatch_acknowledged: 1,
            publication_promoted: 1
          )
        )
        connection[:dispatch_requests].insert(
          dispatch_row(ids).merge(
            request_id: uuid("a"), subject_key: "result-proof", result_state: "pending",
            result_json: "{}", result_digest: "d" * 64,
            result_available_at: timestamp, retain_until: timestamp
          )
        )
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

  private

  def full_index_columns(connection, table)
    connection.fetch("PRAGMA index_list(#{connection.literal(table.to_s)})").filter_map do |row|
      next if row.fetch(:partial) == 1

      connection.fetch("PRAGMA index_info(#{connection.literal(row.fetch(:name))})").all
        .sort_by { |entry| entry.fetch(:seqno) }.map { |entry| entry.fetch(:name) }
    end
  end

  def attempt_row(ids)
    {
      project_id: ids.fetch(:project_id), task_id: ids.fetch(:task_id),
      subject_kind: "task_stage", subject_key: "4-execute", subject_json: "{}",
      task_generation: "task:v1", ownership_generation: "owner:v1",
      state: "running", lease_version: 0, source_fingerprint: "sha256:source",
      record_json: "{}", record_digest: "a" * 64, project_name: "hive",
      task_slug: "sqlite", accepted_date: "2026-08-29", created_at: timestamp,
      accepted_at: timestamp, retry_charge: 0, refunded: 0
    }
  end

  def dispatch_row(ids)
    {
      request_id: uuid("9"), project_id: ids.fetch(:project_id),
      task_id: ids.fetch(:task_id), subject_kind: "task_stage",
      subject_key: "4-execute", task_slug: "sqlite", task_generation: "task:v1",
      intended_stage: "4-execute", state: "queued", priority: 0,
      source_fingerprint: "sha256:request-source", payload_json: "{}",
      created_at: timestamp, updated_at: timestamp
    }
  end

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
