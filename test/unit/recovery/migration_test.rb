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
      assert_equal Hive::Attempts::Record::SCHEMA_VERSION, migrated.fetch("schema_version")
      assert_equal "generation-v1", migrated.fetch("ownership_generation")
      assert_equal 0, migrated.fetch("task_input_epoch")
      assert_equal "generation-v1", migrated.dig("receipt", "ownership_generation")
      assert_equal 0, migrated.dig("receipt", "task_input_epoch")
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

      receipt_path = File.join(state_home, "recovery-migration-v3.json")
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

        assert_equal Hive::Attempts::Record::SCHEMA_VERSION, store.fetch("v1")["schema_version"]
        assert_equal File.join(state_home, "attempts", "v2"), store.root
      end
      refute_path_exists File.join(state_home, "attempts", "v1")
      assert_path_exists File.join(state_home, "recovery-migration-v3.json")
    end
  end

  def test_replaces_the_prior_receipt_and_migrates_v2_attempts_to_v3
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      write_json(File.join(records, "prior.json"), legacy_v2_attempt("prior"))
      write_json(
        File.join(state_home, "recovery-migration-v2.json"),
        {
          "schema" => "hive-recovery-migration",
          "schema_version" => 2,
          "completed_at" => NOW.iso8601(6),
          "attempts" => {},
          "dispatch_requests" => {},
          "dispatch_results" => {}
        }
      )

      result = Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW + 60)

      assert_equal 1, result.dig("attempts", "migrated")
      migrated = JSON.parse(File.binread(File.join(records, "prior.json")))
      assert_equal 3, migrated.fetch("schema_version")
      assert_equal(
        {
          "kind" => "task_stage",
          "task_id" => "42",
          "task_slug" => "durable-task",
          "intended_stage" => "4-execute"
        },
        migrated.fetch("subject")
      )
      assert Hive::Attempts::Record.new(migrated)
      assert_path_exists File.join(state_home, "recovery-migration-v3.json")
      refute_path_exists File.join(state_home, "recovery-migration-v2.json")
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

      assert_includes error.message, "must finish before the recovery cutover"
      refute_path_exists File.join(state_home, "recovery-migration-v3.json")
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
      legacy_root = File.join(state_home, "attempts", "v1")
      FileUtils.mkdir_p(legacy_root)
      File.write(File.join(legacy_root, "unknown-state"), "preserve me")
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v2"))

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "both legacy and current attempt roots exist"
      assert_equal "preserve me", File.read(File.join(legacy_root, "unknown-state"))
    end
  end

  def test_prunes_an_empty_legacy_skeleton_recreated_after_cutover
    with_tmp_dir do |state_home|
      current_records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(current_records)
      write_json(
        File.join(current_records, "current.json"),
        lost_attempt(current_attempt(attempt_id: "current"))
      )
      Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)

      legacy_root = File.join(state_home, "attempts", "v1")
      %w[records logs outputs generation-locks].each do |entry|
        FileUtils.mkdir_p(File.join(legacy_root, entry))
      end

      result = Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW + 60)

      refute_path_exists legacy_root
      assert_path_exists File.join(current_records, "current.json")
      assert_equal (NOW + 60).iso8601(6), result.fetch("completed_at")
    end
  end

  def test_refuses_a_legacy_root_symlink_beside_the_current_root
    with_tmp_dir do |state_home|
      attempts = File.join(state_home, "attempts")
      legacy_target = File.join(state_home, "legacy-target")
      FileUtils.mkdir_p(legacy_target)
      FileUtils.mkdir_p(File.join(attempts, "v2"))
      File.symlink(legacy_target, File.join(attempts, "v1"))

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "both legacy and current attempt roots exist"
      assert File.symlink?(File.join(attempts, "v1"))
    end
  end

  def test_refuses_an_empty_legacy_skeleton_that_gains_state_during_prune
    with_tmp_dir do |state_home|
      legacy_records = File.join(state_home, "attempts", "v1", "records")
      FileUtils.mkdir_p(legacy_records)
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v2"))

      original = Dir.method(:rmdir)
      injected = false
      Dir.define_singleton_method(:rmdir) do |path|
        unless injected
          File.write(File.join(path, "late-state"), "preserve me")
          injected = true
        end
        original.call(path)
      end
      begin
        error = assert_raises(Hive::Recovery::Migration::Error) do
          Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
        end
      ensure
        Dir.define_singleton_method(:rmdir, original)
      end

      assert_includes error.message, "both legacy and current attempt roots exist"
      assert_equal "preserve me", File.read(File.join(legacy_records, "late-state"))
    end
  end

  def test_rejects_an_incomplete_current_completion_receipt
    with_tmp_dir do |state_home|
      write_json(
        File.join(state_home, "recovery-migration-v3.json"),
        {
          "schema" => "hive-recovery-migration",
          "schema_version" => 3
        }
      )

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end
      assert_includes error.message, "receipt is invalid"
    end
  end

  def test_wraps_a_malformed_attempt_parse_error
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      File.write(File.join(records, "malformed.json"), "{")

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "recovery migration failed"
      assert_includes error.message, "expected object key"
    end
  end

  def test_rejects_a_non_attempt_record
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      write_json(
        File.join(records, "other.json"),
        { "schema" => "other-record", "schema_version" => 2 }
      )

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "is not a hive-attempt record"
    end
  end

  def test_refuses_a_live_compatibility_record_already_in_the_current_root
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      write_json(
        File.join(records, "compat-live.json"),
        current_attempt(attempt_id: "compat-live").merge("compatibility" => true)
      )

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "live legacy compatibility attempt"
    end
  end

  def test_rejects_an_unknown_attempt_schema_version
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      write_json(
        File.join(records, "future.json"),
        current_attempt(attempt_id: "future").merge("schema_version" => 99)
      )

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "unsupported attempt schema 99"
    end
  end

  def test_tolerates_the_legacy_records_directory_disappearing_during_preflight
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v1", "records"))

      original = Dir.method(:children)
      Dir.define_singleton_method(:children) { |*| raise Errno::ENOENT }
      begin
        result = Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      ensure
        Dir.define_singleton_method(:children, original)
      end

      assert_equal 0, result.dig("attempts", "migrated")
      assert_path_exists File.join(state_home, "attempts", "v2")
    end
  end

  def test_tolerates_a_queue_directory_disappearing_during_enumeration
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "dispatch_requests"))

      original = Dir.method(:children)
      Dir.define_singleton_method(:children) { |*| raise Errno::ENOENT }
      begin
        result = Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      ensure
        Dir.define_singleton_method(:children, original)
      end

      assert_equal 0, result.dig("dispatch_requests", "migrated")
      assert_path_exists File.join(state_home, "recovery-migration-v3.json")
    end
  end

  def test_refuses_to_overwrite_an_archived_compatibility_record
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      archive = File.join(state_home, "attempts", "legacy-v1-records")
      FileUtils.mkdir_p(records)
      FileUtils.mkdir_p(archive)
      write_json(File.join(records, "compat.json"), final_compatibility_attempt)
      write_json(File.join(archive, "compat.json"), final_compatibility_attempt)

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end

      assert_includes error.message, "legacy compatibility archive collision"
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
    terminal_attempt(current_attempt(attempt_id: "v1")).merge(
      "schema_version" => 1,
      "compatibility" => false
    ).tap do |data|
      data.delete("subject")
      data.delete("ownership_generation")
      data.delete("task_input_epoch")
      data.fetch("receipt").delete("ownership_generation")
      data.fetch("receipt").delete("task_input_epoch")
    end
  end

  def legacy_v2_attempt(attempt_id)
    current_attempt(attempt_id: attempt_id).merge("schema_version" => 2).tap do |data|
      data.delete("subject")
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

  def terminal_attempt(data)
    checkpoint = { "progress_token" => data.fetch("progress_token") }
    log_reference = {
      "path" => "logs/#{data.fetch('attempt_id')}.frames",
      "size" => 4,
      "sha256" => "1" * 64
    }
    receipt = {
      "attempt_id" => data.fetch("attempt_id"),
      "task_generation" => data.fetch("task_generation"),
      "ownership_generation" => data.fetch("ownership_generation"),
      "task_input_epoch" => data.fetch("task_input_epoch"),
      "outcome" => "succeeded",
      "exit_status" => 0,
      "started_at" => NOW.iso8601(6),
      "ended_at" => (NOW + 5).iso8601(6),
      "final_checkpoint" => checkpoint,
      "output_references" => [],
      "log_reference" => log_reference
    }
    data.merge(
      "state" => "terminal",
      "outcome" => "succeeded",
      "claim_deadline" => nil,
      "started_at" => NOW.iso8601(6),
      "ended_at" => (NOW + 5).iso8601(6),
      "checkpoint" => checkpoint,
      "log_reference" => log_reference,
      "receipt" => receipt
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
