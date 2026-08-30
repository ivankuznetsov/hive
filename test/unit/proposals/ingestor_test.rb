require "test_helper"
require "hive/proposals/ingestor"

class ProposalIngestorTest < Minitest::Test
  include HiveTestHelper

  def test_ingests_a_submission_once_and_marks_the_source_consumed
    with_tmp_dir do |dir|
      source_store, store, ingestor = stores(dir)
      event = submission
      source_store.admit!(event)

      result = ingestor.ingest!(event.source_event_id, source_commit: "a" * 40)
      replay = ingestor.ingest!(event.source_event_id, source_commit: "a" * 40)

      assert_equal "record", result.kind
      assert_equal event.proposal_id, result.proposal_id
      assert_nil result.event_id
      assert_equal result, replay
      assert_equal "consumed", source_store.status(event.source_event_id).fetch("state")
      projection = store.projection(event.proposal_id)
      assert_equal "draft", projection.status
      assert_equal event.source_event_id, projection.record.source_event_id
      assert_equal "a" * 40, projection.record.provenance.fetch("source_commit")
    end
  end

  def test_ingests_an_evaluation_from_its_historical_admitted_binding
    with_tmp_dir do |dir|
      source_store, store, ingestor = stores(dir)
      source_store.admit!(submission)
      ingestor.ingest!(submission.source_event_id, source_commit: "a" * 40)
      event = evaluation
      source_store.admit!(event)

      result = ingestor.ingest!(event.source_event_id, source_commit: "b" * 40)

      assert_equal "event", result.kind
      assert_match(/\Apev-/, result.event_id)
      projection = store.projection(event.proposal_id)
      assert_equal 1, projection.evaluations.length
      assert_equal "benchmark-reviewer", projection.evaluations.first.dig("evaluator", "id")
      assert_equal "b" * 40, projection.evaluations.first.dig("provenance", "source_commit")
    end
  end

  private

  def stores(dir)
    root = File.join(dir, "proposals", "v1")
    source_store = Hive::Proposals::SourceEventStore.new(root: root)
    store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
    [ source_store, store,
      Hive::Proposals::Ingestor.new(source_store: source_store, store: store) ]
  end

  def id_sequence
    values = %w[
      00000000-0000-4000-8000-000000000011
      00000000-0000-4000-8000-000000000012
    ]
    -> { values.shift || "00000000-0000-4000-8000-000000000099" }
  end

  def submission
    @submission ||= Hive::Proposals::SourceEvent.submission(
      source_event_id: "pse-#{'a' * 64}", proposal_id: proposal_id,
      proposal_binding: proposal_binding(evaluator: nil), task_binding: task_binding,
      proposed_change: "Use a stricter review prompt", motivation: "Improve recall",
      evidence: [ evidence ], created_at: "2026-08-30T12:00:00Z"
    )
  end

  def evaluation
    @evaluation ||= Hive::Proposals::SourceEvent.evaluation(
      source_event_id: "pse-#{'b' * 64}", proposal_id: proposal_id,
      proposal_binding: proposal_binding(evaluator: evaluator), task_binding: task_binding,
      method: { "kind" => "benchmark", "label" => "held-out recall" },
      result: { "outcome" => "pass", "metrics" => { "recall" => 0.91 } },
      rationale: "No protected regression", evidence: [ evidence ], links: [],
      created_at: "2026-08-30T12:05:00Z"
    )
  end

  def proposal_id = "prp-00000000-0000-4000-8000-000000000001"

  def proposal_binding(evaluator:)
    {
      "schema_version" => 1,
      "subject" => {
        "kind" => "skill", "reference" => "agent-skills/reviewer",
        "revision" => "v2", "proposal_id" => proposal_id
      },
      "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" },
      "evaluator" => evaluator, "configuration_fingerprint" => "c" * 64,
      "policy" => {
        "visibility" => "project", "retention" => "project",
        "allowed_link_schemes" => [ "https" ]
      }
    }
  end

  def evaluator
    {
      "id" => "benchmark-reviewer", "fingerprint" => "d" * 64,
      "configuration_fingerprint" => "c" * 64,
      "admission" => {
        "workflows" => [ "coding" ], "stages" => [ "4-execute" ],
        "agent_profiles" => [ "codex" ]
      }
    }
  end

  def task_binding
    {
      "project" => "hive", "task_id" => "43059", "task_slug" => "proposal-task",
      "workflow_id" => "coding", "stage" => "4-execute", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1"
    }
  end

  def evidence
    { "label" => "benchmark", "content" => "score=0.91", "media_type" => "text/plain" }
  end
end
