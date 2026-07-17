require "test_helper"
require "hive/attempts/store"

class AttemptsStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  def test_legal_lifecycle_increments_version_and_persists_terminal_receipt
    with_store do |store|
      launching = store.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      claimed = store.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      first_heartbeat = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      heartbeat = store.heartbeat(first_heartbeat, stale_sec: 30, now: NOW + 3)
      checkpointed = store.checkpoint(heartbeat, checkpoint: checkpoint, now: NOW + 4)
      terminal = store.terminalize(
        checkpointed,
        outcome: "succeeded",
        exit_status: 0,
        final_checkpoint: checkpoint,
        output_references: [ output_reference ],
        log_reference: log_reference,
        now: NOW + 5
      )

      assert_equal [ 0, 1, 2, 3, 4, 5 ],
                   [ launching, claimed, first_heartbeat, heartbeat, checkpointed, terminal ].map(&:lease_version)
      assert_equal "terminal", terminal.state
      assert_equal "succeeded", terminal.outcome
      assert_equal terminal.attempt_id, terminal.receipt.fetch("attempt_id")
      assert_equal terminal.task_generation, terminal.receipt.fetch("task_generation")
      assert_equal terminal.to_h, store.fetch(terminal.attempt_id).to_h
      assert_equal 0o600, File.stat(store.record_path(terminal.attempt_id)).mode & 0o777
    end
  end

  def test_stale_version_wrong_generation_and_wrong_deadline_do_not_mutate
    with_store do |store|
      launching = store.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      stale_version = launching.with("lease_version" => 99)
      wrong_generation = launching.with("task_generation" => "wrong")
      wrong_deadline = launching.with("claim_deadline" => (NOW + 99).iso8601(6))

      [ stale_version, wrong_generation, wrong_deadline ].each do |observed|
        assert_raises(Hive::Attempts::CompareAndSwapFailed) do
          store.claim(
            observed, owner: owner, claim_capability: CLAIM_CAPABILITY,
            first_heartbeat_timeout_sec: 30, now: NOW + 1
          )
        end
      end

      assert_equal launching.to_h, store.fetch(launching.attempt_id).to_h
    end
  end

  def test_claim_and_expiry_have_one_winner_and_final_state_cannot_revive
    with_store do |store|
      launching = store.create_launching(**identity, launch_timeout_sec: 1, now: NOW)
      lost = store.mark_lost(launching, reason: "launch_timeout", now: NOW + 2)

      assert_equal "lost", lost.state
      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        store.claim(
          launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
          first_heartbeat_timeout_sec: 30, now: NOW + 2
        )
      end
      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        store.first_heartbeat(lost, stale_sec: 30, now: NOW + 3)
      end
    end
  end

  def test_claim_requires_the_one_time_capability
    with_store do |store|
      launching = store.create_launching(**identity, launch_timeout_sec: 30, now: NOW)

      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        store.claim(
          launching, owner: owner, claim_capability: "f" * 64,
          first_heartbeat_timeout_sec: 30, now: NOW + 1
        )
      end
      assert_equal launching.to_h, store.fetch(launching.attempt_id).to_h

      forged_observation = launching.with(
        "claim_capability_digest" => Hive::Attempts::Capability.digest("f" * 64)
      )
      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        store.claim(
          forged_observation, owner: owner, claim_capability: "f" * 64,
          first_heartbeat_timeout_sec: 30, now: NOW + 1
        )
      end

      claimed = store.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        store.claim(
          launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
          first_heartbeat_timeout_sec: 30, now: NOW + 1
        )
      end
      assert claimed.claimed?
    end
  end

  def test_task_generation_lock_serializes_competing_creates
    skip "fork unavailable" unless Process.respond_to?(:fork)

    with_tmp_dir do |root|
      readers, writers = 4.times.map { IO.pipe }.transpose
      pids = writers.each_with_index.map do |writer, index|
        fork do
          readers.each(&:close)
          begin
            store = Hive::Attempts::Store.new(root: root)
            created = nil
            store.with_generation_lock("generation-1") do
              existing = store.for_generation("generation-1")
              created = existing.first || store.create_launching(
                **identity.merge(attempt_id: "attempt-#{index}"), launch_timeout_sec: 30, now: NOW
              )
            end
            writer.write(created.attempt_id)
          ensure
            writer.close
          end
          exit! 0
        end
      end
      writers.each(&:close)
      ids = readers.map(&:read)
      pids.each { |pid| Process.wait(pid) }

      assert_equal 1, ids.uniq.size
      assert_equal 1, Hive::Attempts::Store.new(root: root).for_generation("generation-1").size
    end
  end

  def test_corrupt_and_newer_records_fail_closed_during_scan
    with_store do |store|
      FileUtils.mkdir_p(store.records_root)
      File.write(File.join(store.records_root, "broken.json"), "{")
      newer = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30).to_h
      newer["schema_version"] = Hive::Attempts::Record::SCHEMA_VERSION + 1
      File.write(File.join(store.records_root, "newer.json"), JSON.generate(newer))

      scan = store.scan
      assert_empty scan.records
      assert_equal 2, scan.invalid_records.size
      assert scan.invalid_records.all?(&:capacity_reservation?)
    end
  end

  def test_store_surfaces_unreadable_records_and_filesystem_failures
    with_store do |store|
      assert_nil store.fetch("missing")
      File.write(store.record_path("broken"), "{")
      assert_raises(Hive::Attempts::StoreError) { store.fetch("broken") }

      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::EACCES }) do
        assert_raises(Hive::Attempts::StoreError) { store.with_generation_lock("generation") { } }
        assert_raises(Hive::Attempts::StoreError) { store.with_admission_lock { } }
      end

      with_replaced_singleton_method(Hive::AtomicFile, :write, ->(*_args, **_kwargs) { raise Errno::ENOSPC }) do
        assert_raises(Hive::Attempts::StoreError) do
          store.create_launching(**identity.merge(attempt_id: "persist-failure"), launch_timeout_sec: 30, now: NOW)
        end
      end
    end

    with_replaced_singleton_method(FileUtils, :mkdir_p, ->(*_args, **_kwargs) { raise Errno::EACCES }) do
      assert_raises(Hive::Attempts::StoreError) { Hive::Attempts::Store.new(root: "/unavailable") }
    end
  end

  def test_read_only_store_does_not_create_directories
    with_tmp_dir do |dir|
      root = File.join(dir, "missing-attempts")
      store = Hive::Attempts::Store.new(root: root, create_directories: false)

      refute File.exist?(root)
      assert_nil store.fetch("missing")
      assert_empty store.scan.records
      refute File.exist?(root)
    end
  end

  def test_invalid_mutation_immutable_identity_and_unsafe_ids_fail_closed
    with_store do |store|
      launching = store.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      claimed = store.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      assert_raises(Hive::Attempts::StoreError) do
        store.checkpoint(
          running, checkpoint: checkpoint, now: NOW + 3,
          output_references: [ { "path" => "../escape", "size" => 1, "sha256" => "0" * 64 } ]
        )
      end

      changed = launching.with("request_id" => "different")
      assert_raises(Hive::Attempts::StoreError) { store.send(:verify_immutable!, launching, changed) }
      changed = launching.with("worker_argv" => [ "hive", "run", "other-task" ])
      assert_raises(Hive::Attempts::StoreError) { store.send(:verify_immutable!, launching, changed) }
      assert_raises(Hive::Attempts::StoreError) { store.record_path("../unsafe") }
    end
  end

  private

  def with_store
    with_tmp_dir { |root| yield Hive::Attempts::Store.new(root: root) }
  end

  def identity
    {
      attempt_id: "attempt-1",
      request_id: "request-1",
      predecessor_attempt_id: nil,
      task_id: "42",
      project: "demo",
      task_slug: "durable-task",
      intended_stage: "4-execute",
      task_generation: "generation-1",
      progress_token: "progress-1",
      provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
      starting_revision: "a" * 40,
      retry_charge: 0,
      inherited_outputs: []
    }
  end

  def owner
    {
      "pid" => Process.pid,
      "start_fingerprint" => "pid-start",
      "session_id" => Process.getsid(0),
      "process_group_id" => Process.getpgrp
    }
  end

  def checkpoint
    { "revision" => "b" * 40, "progress_token" => "progress-1" }
  end

  def output_reference
    { "path" => "outputs/attempt-1/result.json", "size" => 2, "sha256" => "0" * 64 }
  end

  def log_reference
    { "path" => "logs/attempt-1.frames", "size" => 4, "sha256" => "1" * 64 }
  end
end
