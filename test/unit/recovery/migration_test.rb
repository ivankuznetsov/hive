require "test_helper"
require "json"
require "hive/attempts/store"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/dispatch_result_queue"
require "hive/recovery/migration"

class RecoveryMigrationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 25, 12, 0, 0)

  def test_migrates_all_recovery_state_once_and_leaves_only_current_schemas
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v1", "records")
      FileUtils.mkdir_p(records)
      write_json(File.join(records, "v1.json"), legacy_v1_attempt)
      write_json(
        File.join(records, "current.json"),
        lost_attempt(current_attempt(attempt_id: "current")).merge("compatibility" => false)
      )
      write_json(File.join(records, "compat.json"), final_compatibility_attempt)
      write_legacy_request(state_home)
      write_legacy_result(state_home)
      File.write(File.join(state_home, "dispatch_requests", "malformed.json"), "{")

      result = Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)

      refute_path_exists File.join(state_home, "attempts", "v1")
      assert_path_exists File.join(state_home, "attempts", "v2", "records")
      assert_equal(
        { "migrated" => 1, "normalized" => 1, "archived_legacy_compatibility" => 1 },
        result.fetch("attempts")
      )

      migrated = JSON.parse(
        File.binread(File.join(state_home, "attempts", "v2", "records", "v1.json"))
      )
      assert_equal 2, migrated.fetch("schema_version")
      assert_equal "generation-v1", migrated.fetch("ownership_generation")
      assert_equal 0, migrated.fetch("task_input_epoch")
      refute migrated.key?("compatibility")
      assert Hive::Attempts::Record.new(migrated)

      normalized = JSON.parse(
        File.binread(File.join(state_home, "attempts", "v2", "records", "current.json"))
      )
      refute normalized.key?("compatibility")
      assert Hive::Attempts::Record.new(normalized)
      assert_path_exists File.join(
        state_home, "attempts", "legacy-v1-records", "compat.json"
      )

      rejected = []
      request = Hive::Daemon::DispatchRequestQueue.pending(
        state_home: state_home,
        bad_handler: ->(path:, reason:) { rejected << reason }
      ).fetch(0)
      assert_equal 4, request.schema_version
      assert_nil request.task_generation
      assert_empty request.inherited_outputs
      assert_nil request.recovery
      assert_equal [ "malformed_json" ], rejected

      notice = Hive::Daemon::DispatchResultQueue.pending(state_home: state_home).fetch(0)
      assert_equal 2, notice.schema_version
      assert_nil notice.attempt_id
      assert_nil notice.receipt

      receipt_path = File.join(state_home, "recovery-migration-v2.json")
      assert_path_exists receipt_path
      assert_equal result, Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW + 60)
    end
  end

  def test_explicit_cutover_prepares_the_default_store
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v1", "records")
      FileUtils.mkdir_p(records)
      write_json(File.join(records, "v1.json"), legacy_v1_attempt)

      with_env("HIVE_HOME" => state_home) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
        store = Hive::Attempts::Store.new

        assert_equal 2, store.fetch("v1")["schema_version"]
        assert_equal File.join(state_home, "attempts", "v2"), store.root
      end
      refute_path_exists File.join(state_home, "attempts", "v1")
      assert_path_exists File.join(state_home, "recovery-migration-v2.json")
    end
  end

  def test_default_store_fails_closed_until_legacy_state_is_migrated
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v1"))

      with_env("HIVE_HOME" => state_home) do
        error = assert_raises(Hive::Attempts::StoreError) do
          Hive::Attempts::Store.new
        end
        assert_includes error.message, "run `hive migrate`"
      end
      refute_path_exists File.join(state_home, "attempts", "v2")
    end
  end

  def test_refuses_to_cut_over_a_live_compatibility_record
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v1", "records")
      FileUtils.mkdir_p(records)
      live = current_attempt(attempt_id: "compat-live").merge(
        "compatibility" => true,
        "worker_argv" => [],
        "claim_capability_digest" => nil,
        "state" => "running",
        "claim_deadline" => nil,
        "heartbeat_deadline" => (NOW + 30).iso8601(6),
        "wrapper" => owner,
        "heartbeat_at" => NOW.iso8601(6),
        "started_at" => NOW.iso8601(6)
      )
      write_json(File.join(records, "compat-live.json"), live)

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "must finish before the v2 cutover"
      refute_path_exists File.join(state_home, "recovery-migration-v2.json")
    end
  end

  def test_refuses_to_move_a_live_durable_attempt_owned_by_an_old_supervisor
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v1", "records")
      FileUtils.mkdir_p(records)
      live = current_attempt(attempt_id: "durable-live").merge("compatibility" => false)
      write_json(File.join(records, "durable-live.json"), live)

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "live attempt in the legacy root"
      assert_path_exists File.join(state_home, "attempts", "v1")
      refute_path_exists File.join(state_home, "attempts", "v2")
    end
  end

  def test_refuses_ambiguous_attempt_roots
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v1"))
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v2"))

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "both legacy and current attempt roots exist"
    end
  end

  def test_rejects_an_incomplete_completion_receipt
    with_tmp_dir do |state_home|
      write_json(
        File.join(state_home, "recovery-migration-v2.json"),
        {
          "schema" => "hive-recovery-migration",
          "schema_version" => 2
        }
      )

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end
      assert_includes error.message, "receipt is invalid"
    end
  end

  private

  def current_attempt(attempt_id:)
    Hive::Attempts::Record.launching(
      attempt_id: attempt_id,
      request_id: "request-#{attempt_id}",
      predecessor_attempt_id: nil,
      task_id: "42",
      project: "demo",
      task_slug: "durable-task",
      intended_stage: "4-execute",
      task_generation: "generation-#{attempt_id}",
      progress_token: "progress-#{attempt_id}",
      provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil,
      retry_charge: 0,
      inherited_outputs: [],
      launch_timeout_sec: 30,
      now: NOW
    ).to_h
  end

  def legacy_v1_attempt
    lost_attempt(current_attempt(attempt_id: "v1")).merge(
      "schema_version" => 1,
      "compatibility" => false
    ).tap do |data|
      data.delete("ownership_generation")
      data.delete("task_input_epoch")
    end
  end

  def final_compatibility_attempt
    lost_attempt(current_attempt(attempt_id: "compat")).merge(
      "compatibility" => true,
      "worker_argv" => [],
      "claim_capability_digest" => nil
    )
  end

  def lost_attempt(data)
    data.merge(
      "state" => "lost",
      "claim_deadline" => nil,
      "ended_at" => NOW.iso8601(6),
      "loss" => { "reason" => "owner_gone", "at" => NOW.iso8601(6) }
    )
  end

  def write_legacy_request(state_home)
    root = File.join(state_home, "dispatch_requests")
    FileUtils.mkdir_p(root)
    write_json(
      File.join(root, "legacy.json"),
      {
        "schema" => "hive-dispatch-request",
        "schema_version" => 2,
        "request_id" => "legacy-request",
        "created_at" => NOW.iso8601(6),
        "project" => "demo",
        "slug" => "durable-task",
        "argv" => [ "hive", "run", "durable-task" ],
        "requestor" => "healer",
        "chat_id" => nil,
        "update_id" => nil,
        "trigger" => "retry"
      }
    )
  end

  def write_legacy_result(state_home)
    root = File.join(state_home, "dispatch_results")
    FileUtils.mkdir_p(root)
    write_json(
      File.join(root, "legacy.json"),
      {
        "schema" => "hive-dispatch-result",
        "schema_version" => 1,
        "result_id" => "abcd1234",
        "created_at" => NOW.iso8601,
        "chat_id" => 42,
        "project" => "demo",
        "slug" => "durable-task",
        "request_id" => "legacy-request",
        "exit_code" => 1,
        "command" => "hive run durable-task"
      }
    )
  end

  def write_json(path, data)
    File.write(path, JSON.generate(data))
  end

  def owner
    {
      "pid" => Process.pid,
      "start_fingerprint" => "start",
      "session_id" => Process.getsid(0),
      "process_group_id" => Process.getpgrp
    }
  end
end
