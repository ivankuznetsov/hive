require "test_helper"
require "hive/attempts/pending_bookkeeping"

class AttemptsPendingBookkeepingTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 7, 16, 12)
  OWNER = { "pid" => 123, "start_fingerprint" => "owner", "session_id" => 123, "process_group_id" => 123 }.freeze
  SECRET = "c" * 64

  def test_prepared_completion_is_private_and_replays_exact_receipt_after_restart
    with_running do |store, record|
      receipt = receipt_for(store, record)
      pending = Hive::Attempts::PendingBookkeeping.new(store: store)
      path = pending.prepare_completion(record, receipt: receipt)
      assert_equal 0o600, File.stat(path).mode & 0o777
      refute_includes File.read(path), SECRET
      restarted = Hive::Attempts::PendingBookkeeping.new(store: store)
      result = restarted.read(record)
      assert_equal :valid, result.status
      terminal = restarted.replay(record, result.document)
      assert_equal receipt, terminal.receipt
      assert_equal terminal.to_h, restarted.replay(record, result.document).to_h
      assert_path_exists path
    end
  end

  private

  def with_running
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      launching = store.create_launching(
        attempt_id: "pending-attempt", request_id: "pending-request", task_id: "42",
        project: "demo", task_slug: "durable-task", intended_stage: "4-execute",
        task_generation: "generation", progress_token: "progress", provider: "codex",
        worker_argv: [ "/bin/true" ], claim_capability_digest: Hive::Attempts::Capability.digest(SECRET),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
      )
      claimed = store.claim(launching, owner: OWNER, claim_capability: SECRET, first_heartbeat_timeout_sec: 30, now: NOW)
      running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 1)
      store.output_directory(running.attempt_id, create: true)
      writer = store.log_archive.open_writer(running.attempt_id)
      writer.append(:stdout, "completed work\n")
      writer.close
      yield store, running
    end
  end

  def receipt_for(store, record)
    store.prepare_terminal_receipt(
      record, outcome: "succeeded", exit_status: 0, final_checkpoint: record.checkpoint,
      output_references: [], log_reference: Hive::OutputReference.build(store.log_archive.hot_path(record.attempt_id), root: store.root),
      now: NOW + 2
    )
  end
end
