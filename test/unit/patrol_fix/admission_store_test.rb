require "test_helper"
require "tmpdir"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/source_snapshot"

class PatrolFixAdmissionStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 20, 12)

  def test_reservation_is_exactly_replayable_and_conflicting_identity_fails_closed
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      snapshot = source_snapshot

      first = store.reserve!(occurrence_id: "ordinary-finding-1-v1", snapshot: snapshot, now: NOW)
      replay = store.reserve!(occurrence_id: "ordinary-finding-1-v1", snapshot: snapshot, now: NOW + 10)

      assert_equal first, replay
      assert_equal "pending", replay.fetch("status")
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.reserve!(
          occurrence_id: "ordinary-finding-1-v1",
          snapshot: source_snapshot(identity: "finding-2"),
          now: NOW
        )
      end
    end
  end

  def test_stale_candidate_digest_is_rejected_and_insufficient_evidence_stays_visible
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot, now: NOW)
      prepared = store.prepare_decision!(
        "ordinary-finding-1-v1",
        candidates: [ candidate("task-a") ],
        current_head: "2" * 40,
        now: NOW
      )

      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        store.record_decision!(
          "ordinary-finding-1-v1",
          candidate_digest: "f" * 64,
          reservation_id: prepared.dig("decision_reservation", "reservation_id"),
          decision: "distinct",
          rationale: "different root",
          evidence: [ "Different failing contract." ],
          model_receipt: "fake-provider:1",
          now: NOW
        )
      end

      blocked = store.record_decision!(
        "ordinary-finding-1-v1",
        candidate_digest: prepared.fetch("candidate_digest"),
        reservation_id: prepared.dig("decision_reservation", "reservation_id"),
        decision: "insufficient_evidence",
        rationale: "The current evidence cannot distinguish the roots.",
        evidence: [ "Affected files overlap but failure modes are unclear." ],
        model_receipt: "fake-provider:2",
        now: NOW
      )

      assert_equal "blocked", blocked.fetch("status")
      assert_nil blocked["task"]
      assert_nil blocked["acknowledgement"]
      assert_equal [ blocked ], store.visible_blocked
    end
  end

  def test_persisted_record_rejects_forged_snapshot_and_candidate_digests
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot, now: NOW)
      prepared = store.prepare_decision!(
        "ordinary-finding-1-v1",
        candidates: [ candidate("task-a") ],
        current_head: "2" * 40,
        now: NOW
      )
      path = File.join(dir, "records", "ordinary-finding-1-v1.json")

      tampered = JSON.parse(File.binread(path))
      tampered["source_digest"] = "f" * 64
      File.binwrite(path, Hive::PatrolFix.canonical_json(tampered))
      assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
        store.fetch("ordinary-finding-1-v1")
      end

      tampered["source_digest"] = source_snapshot.digest
      tampered["candidate_digest"] = "e" * 64
      File.binwrite(path, Hive::PatrolFix.canonical_json(tampered))
      error = assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
        store.fetch("ordinary-finding-1-v1")
      end
      assert_includes error.message, "candidate digest"
      refute_equal prepared.fetch("candidate_digest"), tampered.fetch("candidate_digest")
    end
  end

  def test_decision_reservation_binds_full_inventory_context_and_fences_an_expired_child
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      occurrence = "ordinary-finding-1-v1"
      selected = [ candidate("task-a") ]
      inventory = {
        "count" => 70, "digest" => "b" * 64,
        "context_digest" => Digest::SHA256.hexdigest(
          Hive::PatrolFix.canonical_json(selected)
        ),
        "truncated" => true
      }
      store.reserve!(occurrence_id: occurrence, snapshot: source_snapshot, now: NOW)
      first = store.prepare_decision!(
        occurrence, candidates: selected, current_head: "2" * 40,
        inventory: inventory, reservation_id: "c" * 64,
        lease_expires_at: NOW + 60, now: NOW
      )

      assert_equal 70, first.dig("candidate_inventory", "count")
      assert_equal "b" * 64, first.dig("candidate_inventory", "digest")
      assert_equal "c" * 64, first.dig("decision_reservation", "reservation_id")
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.prepare_decision!(
          occurrence, candidates: selected, current_head: "2" * 40,
          inventory: inventory, reservation_id: "d" * 64,
          lease_expires_at: NOW + 120, now: NOW + 30
        )
      end

      expired = assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        store.record_decision!(
          occurrence, candidate_digest: first.fetch("candidate_digest"),
          reservation_id: "c" * 64, decision: "distinct", rationale: "Different root",
          evidence: [ "Different failure owner" ], model_receipt: "provider:expired",
          now: NOW + 61
        )
      end
      assert_match(/expired/, expired.message)

      replacement = store.prepare_decision!(
        occurrence, candidates: selected, current_head: "2" * 40,
        inventory: inventory, reservation_id: "d" * 64,
        lease_expires_at: NOW + 180, now: NOW + 61
      )
      assert_equal "d" * 64, replacement.dig("decision_reservation", "reservation_id")
      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        store.record_decision!(
          occurrence, candidate_digest: first.fetch("candidate_digest"),
          reservation_id: "c" * 64, decision: "distinct", rationale: "Different root",
          evidence: [ "Different failure owner" ], model_receipt: "provider:old",
          now: NOW + 62
        )
      end
      settled = store.record_decision!(
        occurrence, candidate_digest: replacement.fetch("candidate_digest"),
        reservation_id: "d" * 64, decision: "distinct", rationale: "Different root",
        evidence: [ "Different failure owner" ], model_receipt: "provider:new",
        now: NOW + 62
      )

      assert_equal "decided", settled.fetch("status")
      assert_nil settled["decision_reservation"]
    end
  end

  def test_rejects_a_selected_context_digest_that_does_not_bind_candidate_bytes
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot, now: NOW)

      error = assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.prepare_decision!(
          "ordinary-finding-1-v1", candidates: [ candidate("task-a") ],
          current_head: "2" * 40,
          inventory: {
            "count" => 1, "digest" => "b" * 64,
            "context_digest" => "c" * 64, "truncated" => false
          },
          reservation_id: "d" * 64, lease_expires_at: NOW + 60, now: NOW
        )
      end
      assert_match(/context digest/i, error.message)
    end
  end

  def test_one_store_drives_replay_through_task_binding_and_acknowledgement
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      occurrence = "ordinary-finding-1-v1"
      store.reserve!(occurrence_id: occurrence, snapshot: source_snapshot, now: NOW)
      prepared = store.prepare_decision!(
        occurrence, candidates: [], current_head: "2" * 40, now: NOW
      )
      store.record_decision!(
        occurrence, candidate_digest: prepared.fetch("candidate_digest"),
        reservation_id: prepared.dig("decision_reservation", "reservation_id"),
        decision: "distinct", rationale: "Different root",
        evidence: [ "No exact candidate" ], model_receipt: "fake:distinct", now: NOW
      )
      assert_equal [ occurrence ], store.pending.map { |record| record.fetch("occurrence_id") }

      binding = {
        "slug" => "repair-refresh-abc123", "generation" => 1,
        "evidence_digest" => "a" * 64
      }
      store.begin_materialization!(
        occurrence,
        intent: binding.merge(
          "idempotency_key" => occurrence, "input_fingerprint" => "b" * 64
        ),
        now: NOW
      )
      store.bind_task!(occurrence, task: binding, now: NOW)
      assert_equal "bound", store.pending.fetch(0).fetch("status")

      acknowledged = store.acknowledge!(occurrence, now: NOW)
      replay = store.acknowledge!(occurrence, now: NOW + 60)

      assert_equal acknowledged, replay
      assert_match(/\Aadmission:[0-9a-f]{64}\z/,
                   acknowledged.dig("acknowledgement", "receipt_id"))
      assert_empty store.pending
    end
  end

  def test_pending_skips_live_semantic_leases_without_hiding_new_work
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "a-live-decision", snapshot: source_snapshot, now: NOW)
      store.prepare_decision!(
        "a-live-decision", candidates: [], current_head: "2" * 40,
        lease_expires_at: NOW + 60, now: NOW
      )
      store.reserve!(
        occurrence_id: "b-new-work", snapshot: source_snapshot(identity: "finding-2"), now: NOW
      )

      assert_equal "b-new-work", store.pending(limit: 1, now: NOW).fetch(0).fetch("occurrence_id")
      assert_equal "a-live-decision",
                   store.pending(limit: 1, now: NOW + 61).fetch(0).fetch("occurrence_id")
    end
  end

  def test_pending_reads_the_inventory_with_one_native_anchor_open
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      %w[c-pending a-pending b-pending].each_with_index do |occurrence, index|
        store.reserve!(
          occurrence_id: occurrence,
          snapshot: source_snapshot(identity: "finding-#{index}"),
          now: NOW
        )
      end
      directory = store.instance_variable_get(:@directory)
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_absolute_directory)
      anchor_opens = 0

      pending = with_replaced_singleton_method(
        native,
        :open_absolute_directory,
        lambda do |path|
          anchor_opens += 1
          original_open.call(path)
        end
      ) do
        store.pending
      end

      assert_equal %w[a-pending b-pending c-pending],
                   pending.map { |record| record.fetch("occurrence_id") }
      assert_equal 1, anchor_opens
    end
  end

  def test_pending_does_not_create_a_missing_store
    Dir.mktmpdir do |dir|
      root = File.join(dir, "admissions")
      store = Hive::PatrolFix::AdmissionStore.new(root: root)

      assert_empty store.pending
      refute_path_exists root
    end
  end

  def test_pending_directory_traversal_does_not_grow_with_inventory
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "a-pending", snapshot: source_snapshot, now: NOW)
      directory = store.instance_variable_get(:@directory)
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_directory)

      measure_opens = lambda do
        opens = 0
        with_replaced_singleton_method(
          native,
          :open_directory,
          lambda do |parent, name|
            opens += 1
            original_open.call(parent, name)
          end
        ) { store.pending }
        opens
      end

      one_record_opens = measure_opens.call
      %w[b-pending c-pending].each_with_index do |occurrence, index|
        store.reserve!(
          occurrence_id: occurrence,
          snapshot: source_snapshot(identity: "finding-extra-#{index}"),
          now: NOW
        )
      end

      assert_equal one_record_opens, measure_opens.call
    end
  end

  def test_pending_rejects_unknown_inventory_entries_before_reading_records
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "known", snapshot: source_snapshot, now: NOW)
      File.binwrite(File.join(dir, "records", "unknown-entry"), "unexpected")
      directory = store.instance_variable_get(:@directory)
      reads = []
      original_read = directory.method(:read_children)

      error = with_replaced_singleton_method(
        directory,
        :read_children,
        lambda do |*args, **kwargs, &block|
          reads << args
          original_read.call(*args, **kwargs, &block)
        end
      ) do
        assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) { store.pending }
      end

      assert_match(/unknown entry/, error.message)
      assert_empty reads
    end
  end

  def test_pending_rejects_inventory_overflow_before_reading_records
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      3.times do |index|
        store.reserve!(
          occurrence_id: "pending-#{index}",
          snapshot: source_snapshot(identity: "finding-#{index}"),
          now: NOW
        )
      end
      directory = store.instance_variable_get(:@directory)
      reads = []
      original_read = directory.method(:read_children)

      error = with_replaced_singleton_method(
        directory,
        :read_children,
        lambda do |*args, **kwargs, &block|
          reads << args
          original_read.call(*args, **kwargs, &block)
        end
      ) do
        with_max_records(2) do
          assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) { store.pending }
        end
      end

      assert_match(/bounded limit/, error.message)
      assert_empty reads
    end
  end

  def test_capacity_compacts_only_acknowledged_records_before_reserving
    with_max_records(1) do
      Dir.mktmpdir do |dir|
        store = Hive::PatrolFix::AdmissionStore.new(root: dir)
        reserve_and_acknowledge(store, "old-terminal")

        current = store.reserve!(
          occurrence_id: "new-pending", snapshot: source_snapshot(identity: "finding-2"), now: NOW
        )

        assert_nil store.fetch("old-terminal")
        assert_equal "new-pending", current.fetch("occurrence_id")
        assert_equal [ "new-pending" ], store.pending.map { |record| record.fetch("occurrence_id") }
      end
    end
  end

  def test_capacity_rejects_a_new_reservation_without_wedging_active_work
    with_max_records(1) do
      Dir.mktmpdir do |dir|
        store = Hive::PatrolFix::AdmissionStore.new(root: dir)
        store.reserve!(occurrence_id: "active", snapshot: source_snapshot, now: NOW)

        assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
          store.reserve!(
            occurrence_id: "overflow", snapshot: source_snapshot(identity: "finding-2"), now: NOW
          )
        end
        assert_equal [ "active" ], store.pending.map { |record| record.fetch("occurrence_id") }
      end
    end
  end

  def test_decision_reset_expiry_cancellation_and_replay_are_fenced
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      occurrence = "decision-fences"
      store.reserve!(occurrence_id: occurrence, snapshot: source_snapshot, now: NOW)
      prepared = store.prepare_decision!(
        occurrence, candidates: [], current_head: "2" * 40,
        reservation_id: "c" * 64, lease_expires_at: NOW + 60, now: NOW
      )
      replay = store.prepare_decision!(
        occurrence, candidates: [], current_head: "2" * 40,
        reservation_id: "c" * 64, lease_expires_at: NOW + 60, now: NOW
      )
      assert_equal prepared, replay

      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        store.cancel_unlaunched_decision!(occurrence, reservation_id: "d" * 64, now: NOW)
      end
      cancelled = store.cancel_unlaunched_decision!(
        occurrence, reservation_id: "c" * 64, now: NOW
      )
      assert_equal "pending", cancelled.fetch("status")

      prepared = store.prepare_decision!(
        occurrence, candidates: [], current_head: "2" * 40,
        reservation_id: "e" * 64, lease_expires_at: NOW + 60, now: NOW
      )
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.expire_decision!(occurrence, now: NOW + 59)
      end
      assert_equal "pending", store.expire_decision!(occurrence, now: NOW + 60).fetch("status")

      prepared = store.prepare_decision!(
        occurrence, candidates: [], current_head: "2" * 40, now: NOW + 61
      )
      store.record_decision!(
        occurrence, candidate_digest: prepared.fetch("candidate_digest"),
        reservation_id: prepared.dig("decision_reservation", "reservation_id"),
        decision: "distinct", rationale: "distinct", evidence: [ "proof" ],
        model_receipt: "provider:receipt", now: NOW + 61
      )
      assert_equal "pending", store.reset_decided_stale!(occurrence, now: NOW + 62).fetch("status")
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.reset_decided_stale!(occurrence, now: NOW + 63)
      end
    end
  end

  def test_decision_identity_and_materialization_replay_guards
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      occurrence = "materialization-guards"
      store.reserve!(occurrence_id: occurrence, snapshot: source_snapshot, now: NOW)
      prepared = store.prepare_decision!(
        occurrence, candidates: [ candidate("task-a") ], current_head: "2" * 40, now: NOW
      )
      common = {
        candidate_digest: prepared.fetch("candidate_digest"),
        reservation_id: prepared.dig("decision_reservation", "reservation_id"),
        rationale: "same root", evidence: [ "same failing owner" ],
        model_receipt: "provider:receipt", now: NOW
      }
      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        store.record_decision!(occurrence, **common, decision: "same_root",
                               candidate_identity: "missing")
      end
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.record_decision!(occurrence, **common, decision: "distinct",
                               candidate_identity: "task-a")
      end
      store.record_decision!(occurrence, **common, decision: "same_root",
                             candidate_identity: "task-a")

      intent = {
        "slug" => "repair-one", "generation" => 1,
        "evidence_digest" => source_snapshot.evidence_digest,
        "idempotency_key" => occurrence, "input_fingerprint" => "b" * 64
      }
      first = store.begin_materialization!(occurrence, intent: intent, now: NOW)
      assert_equal first, store.begin_materialization!(occurrence, intent: intent, now: NOW)
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.begin_materialization!(
          occurrence, intent: intent.merge("input_fingerprint" => "c" * 64), now: NOW
        )
      end
      assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
        store.bind_task!(occurrence, task: intent.slice("slug", "generation", "evidence_digest")
          .merge("slug" => "other"), now: NOW)
      end
      binding = intent.slice("slug", "generation", "evidence_digest")
      bound = store.bind_task!(occurrence, task: binding, now: NOW)
      assert_equal bound, store.bind_task!(occurrence, task: binding, now: NOW)
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.bind_task!(occurrence, task: binding.merge("slug" => "other"), now: NOW)
      end

      store.reserve!(
        occurrence_id: "pending-materialization", snapshot: source_snapshot(identity: "finding-2"),
        now: NOW
      )
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.begin_materialization!("pending-materialization", intent: intent, now: NOW)
      end
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.bind_task!("pending-materialization", task: binding, now: NOW)
      end
    end
  end

  def test_retry_resume_restores_each_actionable_materialization_phase
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      occurrence = "retry-actionable"
      prepare_distinct(store, occurrence)
      store.record_retry!(
        occurrence, reason: "transient", error_class: "IOError",
        retry_at: NOW + 60, now: NOW
      )
      assert_equal "decided", store.resume_materialization_retry!(
        occurrence, now: NOW + 60
      ).fetch("status")

      intent = {
        "slug" => "repair-retry", "generation" => 1,
        "evidence_digest" => source_snapshot.evidence_digest,
        "idempotency_key" => occurrence, "input_fingerprint" => "b" * 64
      }
      store.begin_materialization!(occurrence, intent: intent, now: NOW + 61)
      store.record_retry!(
        occurrence, reason: "transient", error_class: "IOError",
        retry_at: NOW + 120, now: NOW + 61
      )
      assert_equal "materializing", store.resume_materialization_retry!(
        occurrence, now: NOW + 120
      ).fetch("status")

      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.resume_materialization_retry!(occurrence, now: NOW + 121)
      end
    end
  end

  def test_private_normalizers_and_corrupt_record_guards_reject_malformed_state
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      errors = [
        -> { store.send(:normalize_candidates, [ nil ]) },
        -> { store.send(:normalize_candidates, [ { "kind" => "task" } ]) },
        -> { store.send(:normalize_candidate_inventory, [], candidates: []) },
        -> do
          store.send(
            :normalize_candidate_inventory,
            { "count" => 0, "digest" => "a" * 64, "context_digest" => "b" * 64,
              "truncated" => true }, candidates: []
          )
        end,
        -> do
          store.send(
            :normalize_candidate_inventory,
            { "count" => "bad", "digest" => "a" * 64, "context_digest" => "b" * 64,
              "truncated" => false }, candidates: []
          )
        end,
        -> { store.send(:normalize_decision_reservation, {}) },
        -> { store.send(:normalize_materialization_intent, {}) },
        -> { store.send(:normalize_task_binding, {}) }
      ]
      errors.each do |operation|
        assert_raises(Hive::PatrolFix::AdmissionStore::Conflict, &operation)
      end
      assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
        store.send(:timestamp_value!, "not-a-time", "timestamp")
      end

      store.reserve!(occurrence_id: "corrupt-record", snapshot: source_snapshot, now: NOW)
      path = File.join(dir, "records", "corrupt-record.json")
      File.binwrite(path, "{")
      assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
        store.fetch("corrupt-record")
      end
    end
  end

  def test_racing_replay_revalidates_the_existing_source_inside_the_record_lock
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      snapshot = source_snapshot
      expected = store.reserve!(occurrence_id: "racing-replay", snapshot: snapshot, now: NOW)
      calls = 0
      original = store.method(:fetch)
      store.define_singleton_method(:fetch) do |id|
        calls += 1
        calls == 1 ? nil : original.call(id)
      end

      assert_equal expected, store.reserve!(
        occurrence_id: "racing-replay", snapshot: snapshot, now: NOW + 1
      )

      calls = 0
      store.define_singleton_method(:fetch) do |id|
        calls += 1
        calls == 1 ? nil : original.call(id)
      end
      assert_raises(Hive::PatrolFix::AdmissionStore::Conflict) do
        store.reserve!(
          occurrence_id: "racing-replay", snapshot: source_snapshot(identity: "finding-2"),
          now: NOW + 2
        )
      end
    end
  end

  def test_persisted_state_invariant_corruption_is_rejected_at_read_time
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      occurrence = "invariant-corruption"
      prepare_distinct(store, occurrence)
      path = File.join(dir, "records", "#{occurrence}.json")
      baseline = JSON.parse(File.binread(path))
      mutations = [
        ->(record) { record.delete("updated_at") },
        ->(record) { record.fetch("source")["title"] = "" },
        ->(record) { record.fetch("decision").delete("rationale") },
        ->(record) { record.fetch("decision")["candidate_identity"] = "task-a" },
        ->(record) do
          record["decision_reservation"] = {
            "reservation_id" => "a" * 64, "reserved_at" => NOW.iso8601,
            "expires_at" => (NOW + 60).iso8601
          }
        end,
        ->(record) { record.fetch("decision")["decision"] = "insufficient_evidence" }
      ]
      mutations.each do |mutation|
        record = Marshal.load(Marshal.dump(baseline))
        mutation.call(record)
        File.binwrite(path, Hive::PatrolFix.canonical_json(record))
        assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
          store.fetch(occurrence)
        end
      end

      File.binwrite(path, Hive::PatrolFix.canonical_json(baseline))
      intent = {
        "slug" => "repair-invariant", "generation" => 1,
        "evidence_digest" => source_snapshot.evidence_digest,
        "idempotency_key" => occurrence, "input_fingerprint" => "b" * 64
      }
      store.begin_materialization!(occurrence, intent: intent, now: NOW)
      store.bind_task!(
        occurrence, task: intent.slice("slug", "generation", "evidence_digest"), now: NOW
      )
      store.acknowledge!(occurrence, now: NOW)
      acknowledged = JSON.parse(File.binread(path))
      acknowledged.fetch("acknowledgement").delete("receipt_id")
      File.binwrite(path, Hive::PatrolFix.canonical_json(acknowledged))
      assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) { store.fetch(occurrence) }

      File.binwrite(path, Hive::PatrolFix.canonical_json(baseline))
      store.record_retry!(
        occurrence, reason: "transient", error_class: "IOError",
        retry_at: NOW + 60, now: NOW
      )
      retrying = JSON.parse(File.binread(path))
      retrying.fetch("retry").delete("reason")
      File.binwrite(path, Hive::PatrolFix.canonical_json(retrying))
      assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) { store.fetch(occurrence) }
    end
  end

  def test_managed_directory_safety_failures_are_translated_to_corrupt_records
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "unsafe-store", snapshot: source_snapshot, now: NOW)
      directory = store.instance_variable_get(:@directory)
      directory.define_singleton_method(:with_lock) do |*_args|
        raise Hive::ManagedDirectory::UnsafeError, "unsafe anchor"
      end

      error = assert_raises(Hive::PatrolFix::AdmissionStore::CorruptRecord) do
        store.reset_decided_stale!("unsafe-store", now: NOW)
      end
      assert_match(/unsafe anchor/, error.message)
    end
  end

  private

  def reserve_and_acknowledge(store, occurrence)
    store.reserve!(occurrence_id: occurrence, snapshot: source_snapshot, now: NOW)
    prepared = store.prepare_decision!(
      occurrence, candidates: [], current_head: "2" * 40, now: NOW
    )
    store.record_decision!(
      occurrence, candidate_digest: prepared.fetch("candidate_digest"),
      reservation_id: prepared.dig("decision_reservation", "reservation_id"),
      decision: "distinct", rationale: "Different root", evidence: [ "No candidate" ],
      model_receipt: "provider:distinct", now: NOW
    )
    binding = {
      "slug" => "repair-#{occurrence}", "generation" => 1,
      "evidence_digest" => source_snapshot.evidence_digest
    }
    store.begin_materialization!(
      occurrence,
      intent: binding.merge("idempotency_key" => occurrence, "input_fingerprint" => "b" * 64),
      now: NOW
    )
    store.bind_task!(occurrence, task: binding, now: NOW)
    store.acknowledge!(occurrence, now: NOW)
  end

  def prepare_distinct(store, occurrence)
    store.reserve!(occurrence_id: occurrence, snapshot: source_snapshot, now: NOW)
    prepared = store.prepare_decision!(
      occurrence, candidates: [], current_head: "2" * 40, now: NOW
    )
    store.record_decision!(
      occurrence, candidate_digest: prepared.fetch("candidate_digest"),
      reservation_id: prepared.dig("decision_reservation", "reservation_id"),
      decision: "distinct", rationale: "different root", evidence: [ "proof" ],
      model_receipt: "provider:receipt", now: NOW
    )
  end

  def with_max_records(limit)
    original = Hive::PatrolFix::AdmissionStore::MAX_RECORDS
    Hive::PatrolFix::AdmissionStore.send(:remove_const, :MAX_RECORDS)
    Hive::PatrolFix::AdmissionStore.const_set(:MAX_RECORDS, limit)
    yield
  ensure
    Hive::PatrolFix::AdmissionStore.send(:remove_const, :MAX_RECORDS)
    Hive::PatrolFix::AdmissionStore.const_set(:MAX_RECORDS, original)
  end

  def source_snapshot(identity: "finding-1")
    Hive::PatrolFix::SourceSnapshot.build(
      engine: "ordinary_patrol", identity: identity, title: "Repair refresh",
      summary: "Refresh fails", target_revision: "1" * 40,
      evidence: [ "Reachable failure" ], affected_code: [ "lib/demo.rb" ],
      reproduction_guidance: "Run focused test", discovery_run: "run-1",
      semantic_lineage: [ "refresh" ], aliases: [], external_issues: [],
      existing_pull_requests: [], accepted_at: NOW.iso8601
    )
  end

  def candidate(slug)
    {
      "kind" => "task", "identity" => slug, "evidence_digest" => "a" * 64,
      "target_revision" => "1" * 40
    }
  end
end
