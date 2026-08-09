require "test_helper"
require "date"
require "json"
require "hive/attempts/store"
require "hive/attempts/permanent_proof_store"
require "hive/attempts/decision_index"
require "hive/attempts/pending_finalization_store"

class AttemptsStorageFoundationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 9, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  def test_store_fetches_permanent_proof_without_enumerating_it
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      proofs = 64.times.map do |index|
        terminal = terminal_record(
          store,
          attempt_id: "cold-attempt-#{index}",
          request_id: "cold-request-#{index}",
          now: NOW + index
        )
        store.permanent_proofs.publish(terminal)
        File.unlink(store.record_path(terminal.attempt_id))
        terminal
      end

      scan = store.scan

      assert_empty scan.records
      assert_empty scan.invalid_records
      assert_equal proofs.last.to_h, store.fetch(proofs.last.attempt_id).to_h
      assert_equal Hive::Attempts::Record::SCHEMA_VERSION,
                   store.fetch(proofs.last.attempt_id)["schema_version"]
    end
  end

  def test_hot_record_wins_during_interrupted_proof_promotion
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      hot = terminal_record(store, attempt_id: "duplicate", request_id: "request")
      proof = hot.with("diagnostics" => { "copy" => "proof" })
      store.permanent_proofs.publish(proof)

      fetched = store.fetch(hot.attempt_id)

      assert_equal hot.to_h, fetched.to_h
      refute_equal proof["diagnostics"], fetched["diagnostics"]
    end
  end

  def test_proof_is_immutable_and_invalid_collision_or_symlink_fails_closed
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      proof = Hive::Attempts::PermanentProofStore.new(
        root: File.join(root, "proof")
      )
      terminal = terminal_record(source, attempt_id: "proof-attempt", request_id: "request")

      assert_equal terminal.to_h, proof.publish(terminal).to_h
      assert_equal terminal.to_h, proof.publish(terminal).to_h
      assert_equal 0o600, File.stat(proof.path_for(terminal.attempt_id)).mode & 0o777

      conflicting = terminal.with("diagnostics" => { "changed" => true })
      assert_raises(Hive::Attempts::StoreError) { proof.publish(conflicting) }

      collision = terminal_record(
        source,
        attempt_id: "other-attempt",
        request_id: "other-request",
        now: NOW + 10
      )
      File.binwrite(proof.path_for(terminal.attempt_id), JSON.generate(collision.to_h) + "\n")
      assert_raises(Hive::Attempts::StoreError) { proof.fetch(terminal.attempt_id) }

      outside = File.join(root, "outside-proof.json")
      File.write(outside, "outside")
      File.unlink(proof.path_for(terminal.attempt_id))
      File.symlink(outside, proof.path_for(terminal.attempt_id))
      assert_raises(Hive::Attempts::StoreError) { proof.fetch(terminal.attempt_id) }
      assert_equal "outside", File.binread(outside)
    end
  end

  def test_decision_indexes_preserve_newest_order_and_successful_owner
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      index = Hive::Attempts::DecisionIndex.new(root: File.join(root, "indexes"))
      older = terminal_record(
        source,
        attempt_id: "attempt-a",
        request_id: "same-request",
        outcome: "failed",
        exit_status: 1,
        now: NOW
      )
      successful = terminal_record(
        source,
        attempt_id: "attempt-b",
        request_id: "same-request",
        outcome: "succeeded",
        exit_status: 0,
        now: NOW + 10
      )
      newest_failure = terminal_record(
        source,
        attempt_id: "attempt-c",
        request_id: "same-request",
        outcome: "failed",
        exit_status: 2,
        now: NOW + 20
      )

      [ successful, older, newest_failure, successful ].each do |record|
        index.record_terminal(record)
      end

      assert_equal newest_failure.attempt_id,
                   index.terminal_attempt_id(request_id: "same-request")
      assert_equal successful.attempt_id, index.successful_attempt_id(
        task_generation: successful.task_generation,
        subject: successful.subject
      )
    end
  end

  def test_loss_successor_and_daily_accounting_primitives_are_idempotent
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      index = Hive::Attempts::DecisionIndex.new(root: File.join(root, "indexes"))
      lost = lost_record(source, attempt_id: "lost-attempt", request_id: "lost-request")
      successor = source.create_launching(
        **identity(
          attempt_id: "successor-attempt",
          request_id: "successor-request",
          predecessor_attempt_id: lost.attempt_id
        ),
        launch_timeout_sec: 30,
        now: NOW + 2
      )

      index.record_unresolved_loss(lost)
      index.record_unresolved_loss(lost)
      assert_equal lost.attempt_id, index.unresolved_loss_attempt_id(
        task_generation: lost.task_generation,
        subject: lost.subject
      )

      index.record_successor(successor)
      index.record_successor(successor)
      assert_equal successor.attempt_id,
                   index.successor_attempt_id(predecessor_attempt_id: lost.attempt_id)
      assert_nil index.unresolved_loss_attempt_id(
        task_generation: lost.task_generation,
        subject: lost.subject
      )

      tempfail = terminal_record(
        source,
        attempt_id: "tempfail-attempt",
        request_id: "tempfail-request",
        outcome: "failed",
        exit_status: Hive::ExitCodes::TEMPFAIL,
        now: NOW + 5
      )
      2.times { index.record_acceptance(tempfail) }
      assert_equal 1, index.daily_count(project: "demo", date: NOW.to_date)

      other_project = terminal_record(
        source,
        attempt_id: "other-project-attempt",
        request_id: "other-project-request",
        now: NOW + 10
      ).with("project" => "other")
      index.record_acceptance(other_project)
      assert_equal(
        {
          [ "demo", NOW.to_date ] => 1,
          [ "other", NOW.to_date ] => 1
        },
        index.daily_counts(date: NOW.to_date)
      )

      2.times { index.refund_tempfail(tempfail) }
      assert_equal 0, index.daily_count(project: "demo", date: NOW.to_date)
    end
  end

  def test_live_capacity_reservations_are_bounded_idempotent_and_identity_checked
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      index = store.decision_index

      store.with_admission_lock do
        2.times do
          index.reserve_live(
            attempt_id: "attempt-1", project: "demo", task_slug: "durable-task"
          )
        end
        assert_equal "pending", index.live_reservations.dig("attempt-1", "phase")

        2.times do
          index.confirm_live(
            attempt_id: "attempt-1", project: "demo", task_slug: "durable-task"
          )
        end
        assert_equal "active", index.live_reservations.dig("attempt-1", "phase")
        assert_raises(Hive::Attempts::StoreError) do
          index.reserve_live(
            attempt_id: "attempt-1", project: "other", task_slug: "durable-task"
          )
        end

        2.times { index.release_live(attempt_id: "attempt-1") }
        assert_empty index.live_reservations
      end
    end
  end

  def test_decision_index_verifies_embedded_compound_key_and_refuses_symlinks
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      index_root = File.join(root, "indexes")
      index = Hive::Attempts::DecisionIndex.new(root: index_root)
      terminal = terminal_record(source, attempt_id: "indexed", request_id: "request/key")
      index.record_terminal(terminal)
      path = index.path_for(
        "terminal-request", { "request_id" => terminal["request_id"] }
      )
      payload = JSON.parse(File.binread(path))
      payload["key"] = { "request_id" => "colliding-request" }
      File.binwrite(path, JSON.generate(payload) + "\n")

      assert_raises(Hive::Attempts::StoreError) do
        index.terminal_attempt_id(request_id: terminal["request_id"])
      end

      File.unlink(path)
      outside = File.join(root, "outside-index.json")
      File.write(outside, "outside")
      File.symlink(outside, path)
      assert_raises(Hive::Attempts::StoreError) do
        index.terminal_attempt_id(request_id: terminal["request_id"])
      end
      assert_equal "outside", File.binread(outside)
    end
  end

  def test_pending_finalization_acknowledgements_are_durable_and_idempotent
    with_tmp_dir do |root|
      pending = Hive::Attempts::PendingFinalizationStore.new(
        root: File.join(root, "pending")
      )
      consumers = %w[accounting journal request-delivery]

      created = pending.create(attempt_id: "attempt-1", consumers: consumers)
      assert_equal consumers.sort, created.fetch("consumers").keys.sort
      refute pending.complete?("attempt-1")
      acknowledged = pending.acknowledge("attempt-1", consumer: "journal")
      assert acknowledged["consumers"]["journal"]
      assert_equal acknowledged,
                   pending.acknowledge("attempt-1", consumer: "journal")
      assert_equal acknowledged, pending.fetch("attempt-1")

      %w[accounting request-delivery].each do |consumer|
        pending.acknowledge("attempt-1", consumer: consumer)
      end
      assert pending.complete?("attempt-1")
      assert_raises(Hive::Attempts::StoreError) do
        pending.create(attempt_id: "attempt-1", consumers: [ "different" ])
      end
    end
  end

  def test_pending_finalization_corruption_and_symlink_fail_closed
    with_tmp_dir do |root|
      pending = Hive::Attempts::PendingFinalizationStore.new(
        root: File.join(root, "pending")
      )
      pending.create(attempt_id: "attempt-1", consumers: [ "journal" ])
      path = pending.path_for("attempt-1")
      File.binwrite(path, "{")
      assert_raises(Hive::Attempts::StoreError) { pending.fetch("attempt-1") }

      outside = File.join(root, "outside-pending.json")
      File.write(outside, "outside")
      File.unlink(path)
      File.symlink(outside, path)
      assert_raises(Hive::Attempts::StoreError) { pending.fetch("attempt-1") }
      assert_equal "outside", File.binread(outside)
    end
  end

  private

  def terminal_record(store, attempt_id:, request_id:, outcome: "succeeded", exit_status: 0,
                      now: NOW)
    launching = store.create_launching(
      **identity(attempt_id: attempt_id, request_id: request_id),
      launch_timeout_sec: 30,
      now: now
    )
    claimed = store.claim(
      launching,
      owner: owner,
      claim_capability: CLAIM_CAPABILITY,
      first_heartbeat_timeout_sec: 30,
      now: now + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: now + 2)
    store.terminalize(
      running,
      outcome: outcome,
      exit_status: exit_status,
      final_checkpoint: checkpoint,
      output_references: [],
      log_reference: log_reference(attempt_id),
      now: now + 3
    )
  end

  def lost_record(store, attempt_id:, request_id:)
    launching = store.create_launching(
      **identity(attempt_id: attempt_id, request_id: request_id),
      launch_timeout_sec: 30,
      now: NOW
    )
    store.mark_lost(launching, reason: "owner_gone", now: NOW + 1)
  end

  def identity(attempt_id:, request_id:, predecessor_attempt_id: nil)
    {
      attempt_id: attempt_id,
      request_id: request_id,
      predecessor_attempt_id: predecessor_attempt_id,
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

  def log_reference(attempt_id)
    {
      "path" => "logs/#{attempt_id}.frames",
      "size" => 0,
      "sha256" => "0" * 64
    }
  end
end
