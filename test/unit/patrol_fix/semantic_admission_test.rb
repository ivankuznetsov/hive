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

  def test_one_strict_rich_context_is_bound_to_the_full_inventory_digest
    Dir.mktmpdir do |dir|
      selected = [ rich_candidate("task-a") ]
      inventory_digest = "b" * 64
      candidate_reads = 0
      provider_calls = 0
      provider_input = nil
      candidate_provider = lambda do |_snapshot|
        candidate_reads += 1
        {
          "inventory_count" => 70, "inventory_digest" => inventory_digest,
          "context_digest" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(selected)
          ),
          "truncated" => true, "candidates" => selected
        }
      end
      provider = lambda do |input|
        provider_calls += 1
        provider_input = input
        {
          "decision" => "distinct", "candidate_identity" => nil,
          "rationale" => "Different remediation owner",
          "evidence" => [ "The affected contracts differ" ],
          "model_receipt" => "fake:rich"
        }
      end
      service = Hive::PatrolFix::SemanticAdmission.new(
        store: Hive::PatrolFix::AdmissionStore.new(root: dir),
        candidate_provider: candidate_provider, decision_provider: provider,
        current_head: -> { "2" * 40 }, clock: -> { NOW }
      )
      prepared = service.prepare(
        occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot,
        reservation_id: "c" * 64, lease_expires_at: NOW + 60, now: NOW
      )

      assert_equal 0, provider_calls
      assert_equal 70, prepared.dig("candidate_inventory", "count")
      settled = service.run_reserved(
        occurrence_id: "ordinary-finding-1-v1", reservation_id: "c" * 64,
        now: NOW + 1
      )

      assert_equal "decided", settled.fetch("status")
      assert_equal 1, provider_calls
      assert_equal 3, candidate_reads
      assert_equal 2, provider_input.fetch("schema_version")
      assert provider_input.fetch("candidate_context_truncated")
      assert_equal [ "lib/session/refresh.rb" ],
                   provider_input.dig("candidates", 0, "affected_code")
      assert_equal "Consolidate refresh ownership",
                   provider_input.dig("candidates", 0, "remediation")
    end
  end

  def test_rejects_when_an_unselected_owned_manifest_changes_the_full_inventory_digest
    Dir.mktmpdir do |dir|
      selected = [ rich_candidate("task-a") ]
      inventory_digest = "b" * 64
      provider = lambda do |_input|
        inventory_digest = "c" * 64
        {
          "decision" => "distinct", "candidate_identity" => nil,
          "rationale" => "Different remediation owner",
          "evidence" => [ "The affected contracts differ" ],
          "model_receipt" => "fake:stale-full-inventory"
        }
      end
      candidate_provider = lambda do |_snapshot|
        {
          "inventory_count" => 70, "inventory_digest" => inventory_digest,
          "context_digest" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(selected)
          ),
          "truncated" => true, "candidates" => selected
        }
      end
      service = Hive::PatrolFix::SemanticAdmission.new(
        store: Hive::PatrolFix::AdmissionStore.new(root: dir),
        candidate_provider: candidate_provider, decision_provider: provider,
        current_head: -> { "2" * 40 }, clock: -> { NOW }
      )
      service.prepare(
        occurrence_id: "ordinary-finding-1-v1", snapshot: source_snapshot,
        reservation_id: "d" * 64, lease_expires_at: NOW + 60, now: NOW
      )

      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        service.run_reserved(
          occurrence_id: "ordinary-finding-1-v1", reservation_id: "d" * 64,
          now: NOW + 1
        )
      end
      assert_equal "pending", service.store.fetch("ordinary-finding-1-v1").fetch("status")
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

  def rich_candidate(slug)
    core = candidate(slug).merge(
      "manifest_digest" => "f" * 64,
      "evidence" => [ "Refresh token race" ],
      "affected_code" => [ "lib/session/refresh.rb" ],
      "remediation" => "Consolidate refresh ownership"
    )
    core.merge(
      "context_digest" => Digest::SHA256.hexdigest(
        Hive::PatrolFix.canonical_json(core)
      )
    )
  end
end
