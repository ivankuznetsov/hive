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
