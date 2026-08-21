require "test_helper"
require "tmpdir"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/source_snapshot"

class PatrolFixAdmissionStoreTest < Minitest::Test
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

  def test_operational_records_are_bounded_to_root_cohort_and_retry_facts
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::AdmissionStore.new(root: dir)
      store.reserve!(occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot, now: NOW)
      prepared = store.prepare_decision!(
        "ordinary-finding-1-v1", candidates: [ candidate("task-a") ],
        current_head: "2" * 40, now: NOW
      )
      store.record_decision!(
        "ordinary-finding-1-v1", candidate_digest: prepared.fetch("candidate_digest"),
        reservation_id: prepared.dig("decision_reservation", "reservation_id"),
        decision: "same_root", candidate_identity: "task-a", rationale: "same root",
        evidence: [ "Same failing owner." ], model_receipt: "provider:receipt", now: NOW
      )

      row = store.operational_records.fetch(0)
      assert_equal %w[candidates created_at decision occurrence_id retry status task], row.keys.sort
      assert_equal({ "kind" => "task", "identity" => "task-a" }, row.fetch("candidates").first)
      assert_equal({ "decision" => "same_root", "candidate_identity" => "task-a" }, row.fetch("decision"))
      refute_includes JSON.generate(row), "Same failing owner"
      assert row.frozen?
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

  private

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
