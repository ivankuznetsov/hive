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

  def test_point_storage_enumeration_is_bounded_and_rejects_non_directory_shards
    with_tmp_dir do |root|
      storage = Hive::Attempts::PointStorage.new(root: root, label: "test storage")
      %w[first second].each do |key|
        storage.write(
          "projection", { "id" => key }, "#{key}\n",
          expected_bytes: nil, max_existing_bytes: 1024
        )
      end
      assert_raises(Hive::Attempts::StoreError) do
        storage.each_entry("projection", max_entries: 1, max_bytes: 1024).to_a
      end
      assert_raises(Hive::Attempts::StoreError) do
        storage.each_entry("projection", max_entries: "invalid", max_bytes: 1024).to_a
      end

      broken_root = File.join(root, "broken")
      broken = Hive::Attempts::PointStorage.new(root: broken_root, label: "broken storage")
      FileUtils.mkdir_p(File.join(broken_root, "projection"))
      File.write(File.join(broken_root, "projection", "aa"), "not-a-directory")
      assert_raises(Hive::Attempts::StoreError) do
        broken.each_entry("projection", max_entries: 2, max_bytes: 1024).to_a
      end
    end
  end

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

  def test_projection_binding_skips_unrelated_output_and_receipt_validation
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      terminal = terminal_record(
        source, attempt_id: "projection-proof", request_id: "projection-request"
      )
      store.permanent_proofs.publish(terminal)

      replacement = ->(*) { raise "full record validation must not run" }
      binding = with_replaced_singleton_method(
        Hive::Attempts::Record, :new, replacement
      ) do
        store.fetch_projection_binding(terminal.attempt_id)
      end

      assert_equal terminal.attempt_id, binding.fetch("attempt_id")
      assert_equal terminal.task_input_epoch, binding.fetch("task_input_epoch")
      assert_equal terminal.state, binding.fetch("state")
      assert_equal terminal.outcome, binding.fetch("outcome")
      assert_equal Hive::Attempts::PermanentProofStore::PROJECTION_BINDING_KEYS.sort,
                   binding.keys.sort
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
      advanced = source.claim(
        successor, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 3
      )
      index.record_successor(advanced)
      competing = source.create_launching(
        **identity(
          attempt_id: "newer-successor", request_id: "newer-request",
          predecessor_attempt_id: lost.attempt_id
        ),
        launch_timeout_sec: 30, now: NOW + 4
      )
      index.record_successor(competing)
      assert_equal competing.attempt_id,
                   index.successor_attempt_id(predecessor_attempt_id: lost.attempt_id),
                   "a legacy duplicate converges on the deterministic newest successor"
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

  # A launch that never produced an agent spent nothing, so it must not spend
  # a daily slot. Without this, a night of failed handoffs exhausts the day's
  # budget and locks out the runs that would have succeeded.
  def test_unstarted_loss_refunds_its_daily_slot
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      index = store.decision_index
      lost = lost_record(store, attempt_id: "never-ran", request_id: "request-never-ran")

      assert_nil lost["started_at"], "fixture must never have reached running"
      index.record_acceptance(lost)
      assert_equal 1, index.daily_count(project: "demo", date: NOW.to_date)

      2.times { index.refund_unstarted(lost) }

      assert_equal 0, index.daily_count(project: "demo", date: NOW.to_date)
    end
  end

  # A loss after the agent started keeps its charge: the tokens are already
  # spent, and the daily cap is a spend bound.
  def test_loss_after_starting_is_not_refunded
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      index = store.decision_index
      launching = store.create_launching(
        **identity(attempt_id: "ran-then-lost", request_id: "request-ran-then-lost"),
        launch_timeout_sec: 30, now: NOW
      )
      claimed = store.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      lost = store.mark_lost(running, reason: "owner_gone", now: NOW + 3)

      refute_nil lost["started_at"], "fixture must have reached running"
      index.record_acceptance(lost)

      assert_raises(Hive::Attempts::StoreError) { index.refund_unstarted(lost) }
      assert_equal 1, index.daily_count(project: "demo", date: NOW.to_date)
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
                   pending.create(attempt_id: "attempt-1", consumers: consumers)
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

  def test_storage_keys_reject_unsafe_values_and_point_storage_translates_failures
    assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::StorageKey.normalize(Object.new)
    end
    assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::StorageKey.relative("Invalid", { "id" => "attempt-1" })
    end
    assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::StorageKey.string("\xFF".b)
    end
    assert_raises(ArgumentError) do
      Hive::PointStorage.new(
        root: "/unused", label: "test point", error_class: Object
      )
    end

    replacement = ->(**) { raise ArgumentError, "bad root" }
    with_replaced_singleton_method(Hive::ManagedDirectory, :new, replacement) do
      error = assert_raises(Hive::Attempts::StoreError) do
        Hive::Attempts::PointStorage.new(root: "/unused", label: "test point")
      end
      assert_match(/test point is unavailable: bad root/, error.message)
    end

    with_tmp_dir do |root|
      storage = Hive::Attempts::PointStorage.new(root: root, label: "test point")
      unavailable = Object.new
      unavailable.define_singleton_method(:atomic_write) do |*, **|
        raise IOError, "write failed"
      end
      unavailable.define_singleton_method(:with_lock) do |*, **|
        raise ArgumentError, "lock failed"
      end
      unavailable.define_singleton_method(:unlink) do |*, **|
        raise IOError, "delete failed"
      end
      storage.instance_variable_set(:@directory, unavailable)

      write_error = assert_raises(Hive::Attempts::StoreError) do
        storage.write(
          "cell", { "id" => "attempt-1" }, "{}\n",
          expected_bytes: nil, max_existing_bytes: 100
        )
      end
      assert_match(/test point is unavailable: write failed/, write_error.message)

      yielded = false
      lock_error = assert_raises(Hive::Attempts::StoreError) do
        storage.synchronize("cell", { "id" => "attempt-1" }) { yielded = true }
      end
      refute yielded
      assert_match(/test point is unavailable: lock failed/, lock_error.message)

      delete_error = assert_raises(Hive::Attempts::StoreError) do
        storage.delete(
          "cell", { "id" => "attempt-1" },
          expected_bytes: nil, max_bytes: 100
        )
      end
      assert_match(/test point is unavailable: delete failed/, delete_error.message)
    end
  end

  def test_permanent_proofs_require_final_records_and_reject_unreadable_bytes
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      launching_source = Hive::Attempts::Store.new(root: File.join(root, "launching"))
      proof = Hive::Attempts::PermanentProofStore.new(root: File.join(root, "proof"))
      launching = launching_source.create_launching(
        **identity(attempt_id: "proof-attempt", request_id: "proof-request"),
        launch_timeout_sec: 30,
        now: NOW
      )

      assert_raises(Hive::Attempts::StoreError) { proof.publish(launching) }

      terminal = terminal_record(
        source, attempt_id: launching.attempt_id, request_id: "proof-request"
      )
      proof.publish(terminal)
      path = proof.path_for(terminal.attempt_id)
      File.binwrite(path, JSON.generate(launching.to_h) + "\n")
      assert_raises(Hive::Attempts::StoreError) { proof.fetch(terminal.attempt_id) }
      assert_raises(Hive::Attempts::StoreError) do
        proof.fetch_projection_binding(terminal.attempt_id)
      end

      File.binwrite(path, "{")
      assert_raises(Hive::Attempts::StoreError) { proof.fetch(terminal.attempt_id) }
      assert_raises(Hive::Attempts::StoreError) do
        proof.fetch_projection_binding(terminal.attempt_id)
      end
    end
  end

  def test_pending_finalization_validates_consumers_and_removal_lifecycle
    with_tmp_dir do |root|
      pending = Hive::Attempts::PendingFinalizationStore.new(
        root: File.join(root, "pending")
      )

      assert_raises(Hive::Attempts::StoreError) do
        pending.create(attempt_id: "empty", consumers: [])
      end
      assert_raises(Hive::Attempts::StoreError) do
        pending.create(
          attempt_id: "too-many",
          consumers: 33.times.map { |index| "consumer_#{index}" }
        )
      end
      assert_raises(Hive::Attempts::StoreError) do
        pending.create(attempt_id: "invalid", consumers: [ "Bad Consumer" ])
      end

      pending.create(attempt_id: "attempt-1", consumers: [ "journal" ])
      assert_raises(Hive::Attempts::StoreError) do
        pending.acknowledge("attempt-1", consumer: "accounting")
      end
      assert_raises(Hive::Attempts::StoreError) do
        pending.remove_complete("attempt-1")
      end

      pending.acknowledge("attempt-1", consumer: "journal")
      assert pending.remove_complete("attempt-1")
      assert_nil pending.fetch("attempt-1")
      refute pending.remove_complete("attempt-1")
    end
  end

  def test_decision_indexes_reject_incompatible_records_and_accounting_changes
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      index = Hive::Attempts::DecisionIndex.new(root: File.join(root, "indexes"))
      launching = source.create_launching(
        **identity(attempt_id: "launching", request_id: "launching-request"),
        launch_timeout_sec: 30,
        now: NOW
      )

      assert_raises(Hive::Attempts::StoreError) do
        index.record_unresolved_loss(launching)
      end
      assert_raises(Hive::Attempts::StoreError) { index.record_successor(launching) }
      assert_raises(Hive::Attempts::StoreError) { index.record_acceptance(Object.new) }
      assert_raises(Hive::Attempts::StoreError) { index.record_terminal(launching) }

      succeeded = terminal_record(
        source, attempt_id: "succeeded", request_id: "succeeded-request"
      )
      assert_raises(Hive::Attempts::StoreError) { index.refund_tempfail(succeeded) }
      # A live attempt has not finished losing yet, so its charge is not free
      # to give back even though it never reached running.
      assert_raises(Hive::Attempts::StoreError) { index.refund_unstarted(launching) }

      tempfail = terminal_record(
        source,
        attempt_id: "tempfail",
        request_id: "tempfail-request",
        outcome: "failed",
        exit_status: Hive::ExitCodes::TEMPFAIL,
        now: NOW + 10
      )
      index.record_acceptance(tempfail)
      assert_raises(Hive::Attempts::StoreError) do
        index.record_acceptance(tempfail.with("project" => "other"))
      end
      assert_raises(Hive::Attempts::StoreError) do
        index.refund_tempfail(tempfail.with("project" => "other"))
      end

      unaccepted = terminal_record(
        source,
        attempt_id: "unaccepted",
        request_id: "unaccepted-request",
        outcome: "failed",
        exit_status: Hive::ExitCodes::TEMPFAIL,
        now: NOW + 86_400
      )
      assert_raises(Hive::Attempts::StoreError) { index.refund_tempfail(unaccepted) }
    end
  end

  def test_decision_indexes_enforce_bounded_daily_accounting_and_dates
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      index = Hive::Attempts::DecisionIndex.new(root: File.join(root, "indexes"))
      first = terminal_record(
        source, attempt_id: "first", request_id: "first-request", now: NOW
      )
      second = terminal_record(
        source, attempt_id: "second", request_id: "second-request", now: NOW + 10
      )

      with_constant(Hive::Attempts::DecisionIndex, :MAX_DAILY_ATTEMPTS, 1) do
        index.record_acceptance(first)
        assert_raises(Hive::Attempts::StoreError) { index.record_acceptance(second) }
      end

      assert_equal 1, index.daily_count(project: "demo", date: NOW.to_date.iso8601)
      assert_raises(Hive::Attempts::StoreError) do
        index.daily_count(project: "demo", date: "not-a-date")
      end
    end
  end

  def test_decision_indexes_validate_live_replacement_and_capacity
    with_tmp_dir do |root|
      index = Hive::Attempts::DecisionIndex.new(root: File.join(root, "indexes"))
      index.reserve_live(
        attempt_id: "attempt-1", project: "demo", task_slug: "durable-task"
      )

      assert_raises(Hive::Attempts::StoreError) do
        index.confirm_live(
          attempt_id: "attempt-1", project: "other", task_slug: "durable-task"
        )
      end
      assert_raises(Hive::Attempts::StoreError) do
        index.replace_live_reservations("attempt-2" => {})
      end
      assert_raises(Hive::Attempts::StoreError) do
        index.replace_live_reservations(
          "attempt-2" => {
            "project" => "demo", "task_slug" => "durable-task", "phase" => "stale"
          }
        )
      end

      with_constant(Hive::Attempts::DecisionIndex, :MAX_LIVE_RESERVATIONS, 1) do
        assert_raises(Hive::Attempts::StoreError) do
          index.reserve_live(
            attempt_id: "attempt-2", project: "demo", task_slug: "durable-task"
          )
        end
      end
    end
  end

  def test_decision_indexes_reject_malformed_and_invalid_cells
    with_tmp_dir do |root|
      source = Hive::Attempts::Store.new(root: File.join(root, "source"))
      index = Hive::Attempts::DecisionIndex.new(root: File.join(root, "indexes"))
      terminal = terminal_record(
        source, attempt_id: "indexed", request_id: "indexed-request"
      )
      index.record_terminal(terminal)
      path = index.path_for(
        "terminal-request", { "request_id" => terminal["request_id"] }
      )
      original = JSON.parse(File.binread(path))

      File.binwrite(path, "{")
      assert_raises(Hive::Attempts::StoreError) do
        index.terminal_attempt_id(request_id: terminal["request_id"])
      end

      invalid_outcome = Marshal.load(Marshal.dump(original))
      invalid_outcome.fetch("value")["outcome"] = "unknown"
      File.binwrite(path, Hive::Attempts::StorageKey.dump(invalid_outcome))
      assert_raises(Hive::Attempts::StoreError) do
        index.terminal_attempt_id(request_id: terminal["request_id"])
      end

      invalid_time = Marshal.load(Marshal.dump(original))
      invalid_time.fetch("value")["accepted_at"] = "not-a-time"
      File.binwrite(path, Hive::Attempts::StorageKey.dump(invalid_time))
      assert_raises(Hive::Attempts::StoreError) do
        index.terminal_attempt_id(request_id: terminal["request_id"])
      end
    end
  end

  def test_store_exposes_managed_roots_and_hot_removal_fails_closed
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      assert_equal File.join(root, "decision-indexes"), store.decision_indexes_root
      assert_equal File.join(root, "pending-finalization"), store.pending_finalization_root
      assert_equal File.join(root, "maintenance"), store.maintenance_root

      terminal = terminal_record(
        store, attempt_id: "hot-final", request_id: "hot-final-request"
      )
      changed = terminal.with("diagnostics" => { "changed" => true })
      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        store.remove_hot_final(changed)
      end

      replacement = ->(*) { raise Errno::EACCES, "denied" }
      with_replaced_singleton_method(File, :unlink, replacement) do
        assert_raises(Hive::Attempts::StoreError) { store.remove_hot_final(terminal) }
      end
      assert_equal terminal.to_h, store.fetch_hot(terminal.attempt_id).to_h
    end
  end

  private

  def with_constant(owner, name, replacement)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

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
