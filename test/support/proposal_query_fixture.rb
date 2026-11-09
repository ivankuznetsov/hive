module ProposalQueryFixture
  def setup_proposal_query_fixture
    @root = tracked_tmp_dir("hive-test-proposal-query")
    @store = Hive::Proposals::Store.new(root: @root)
    @draft = proposal_id(1)
    @rejected = proposal_id(2)
    create_record(@draft, revision: "v1")
    create_record(@rejected, revision: "v2", retries: @draft)
    append_evaluation(@rejected, 1, "pass", "recall", 0.91)
    append_evaluation(@rejected, 2, "fail", "cost", 1.4)
    append_rejection(@rejected, 3)
    @query = Hive::Proposals::Query.new(store: @store)
  end

  private

  def create_record(id, revision:, retries: nil)
    @store.create_record!(
      proposal_id: id, subject_kind: "workflow", subject_ref: "coding", revision:,
      proposed_change: "Untrusted change\n# heading", motivation: "Motivation token sk-#{'a' * 30}",
      evidence: [
        { "label" => "private", "content" => "secret", "media_type" => "text/plain" }
      ],
      author: { "id" => "alice", "kind" => "proposer", "binding" => "team" },
      provenance:, source_event_id: source(id == @draft ? 1 : 2),
      lineage: { "retries" => retries }, created_at: "2026-08-30T12:00:00Z"
    )
  end

  def append_evaluation(id, version, outcome, method, metric)
    @store.append_event!(
      proposal_id: id, type: "evaluation", event_id: event_id(version),
      source_event_id: source(10 + version), provenance:, occurred_at: "2026-08-30T12:0#{version}:00Z",
      data: {
        "evaluator" => { "id" => "benchmark-reviewer", "binding_fingerprint" => "b" * 64 },
        "method" => { "kind" => "benchmark", "label" => method },
        "result" => { "outcome" => outcome, "metrics" => { method => metric } },
        "rationale" => "Never include this instruction", "evidence" => [], "links" => []
      }
    )
  end

  def append_rejection(id, version)
    evaluations = @store.projection(id).evaluations
    @store.append_event!(
      proposal_id: id, type: "decision", event_id: event_id(version),
      source_event_id: source(20 + version), provenance:, occurred_at: "2026-08-30T12:03:00Z",
      data: {
        "outcome" => "rejected",
        "considered_evaluation_ids" => evaluations.map { |row| row.fetch("event_id") },
        "considered_evaluations" => evaluations.map do |row|
          {
            "evaluation_id" => row.fetch("event_id"), "evaluator_id" => row.dig("evaluator", "id"),
            "method" => row.dig("method", "label"), "outcome" => row.dig("result", "outcome"),
            "result_digest" => Hive::Proposals.digest(row.fetch("result"))
          }
        end,
        "rationale_category" => "evaluated", "rationale" => "Threshold exceeded",
        "authority" => { "id" => "operator", "kind" => "operator", "policy_fingerprint" => "c" * 64 },
        "links" => [], "observed_head" => @store.projection(id).lifecycle_head
      }
    )
  end

  def proposal_id(number) = format("prp-00000000-0000-4000-8000-%012d", number)
  def event_id(number) = format("pev-00000000-0000-4000-8000-%012d", number)
  def source(number) = "pse-#{number.to_s(16).rjust(64, '0')}"

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner", "attempt_id" => "attempt",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end
end
