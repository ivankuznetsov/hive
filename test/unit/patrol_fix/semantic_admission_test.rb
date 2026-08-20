require "test_helper"
require "tmpdir"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/semantic_admission"
require "hive/patrol_fix/source_snapshot"

class PatrolFixSemanticAdmissionTest < Minitest::Test
  NOW = Time.utc(2026, 8, 20, 12)

  def test_rejects_a_stale_llm_decision_and_does_not_guess_ownership
    Dir.mktmpdir do |dir|
      candidates = [ candidate("task-a") ]
      provider = lambda do |_input|
        candidates << candidate("task-b")
        {
          "decision" => "same_root", "candidate_identity" => "task-a",
          "rationale" => "Same failure", "evidence" => [ "Same branch" ],
          "model_receipt" => "fake:1"
        }
      end
      service = Hive::PatrolFix::SemanticAdmission.new(
        store: Hive::PatrolFix::AdmissionStore.new(root: dir),
        candidate_provider: ->(_snapshot) { candidates.dup },
        decision_provider: provider,
        current_head: -> { "2" * 40 },
        clock: -> { NOW }
      )

      error = assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        service.call(occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot)
      end
      assert_includes error.message, "candidate set changed"
      record = service.store.fetch("ordinary-finding-1-v1")
      assert_equal "pending", record.fetch("status")
      assert_nil record["task"]
      assert_nil record["acknowledgement"]
    end
  end

  private

  def source_snapshot
    Hive::PatrolFix::SourceSnapshot.build(
      engine: "ordinary_patrol", identity: "finding-1", title: "Repair refresh",
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
