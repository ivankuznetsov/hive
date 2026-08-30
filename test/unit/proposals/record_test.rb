require "test_helper"
require "hive/proposals"
require "hive/proposals/record"

class ProposalRecordTest < Minitest::Test
  def test_builds_an_immutable_candidate_and_applies_privacy_before_persistence
    record = Hive::Proposals::Record.build(
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      subject_kind: "skill",
      subject_ref: "agent-skills/reviewer",
      revision: "reviewer-v2",
      proposed_change: "Use api_key=abcdefghijklmnopqrstuv for a stronger review prompt",
      motivation: "Improve held-out recall",
      evidence: [
        {
          "label" => "private benchmark",
          "content" => "raw private transcript",
          "media_type" => "text/plain"
        },
        {
          "label" => "public score",
          "content" => "recall improved to 0.91",
          "visibility" => "project",
          "retention" => "indefinite",
          "media_type" => "text/plain"
        }
      ],
      author: author,
      provenance: provenance,
      source_event_id: "pse-#{'a' * 64}",
      created_at: "2026-08-30T12:00:00Z",
      policy: {
        "visibility" => "project",
        "retention" => "project",
        "allowed_link_schemes" => [ "https" ]
      }
    )

    assert_equal "draft", record.initial_status
    assert_equal "skill", record.subject.fetch("kind")
    assert_includes record["proposed_change"], "[REDACTED:generic_api_key]"
    refute record.evidence.first.key?("summary")
    assert_equal "restricted", record.evidence.first.fetch("visibility")
    assert_equal "recall improved to 0.91", record.evidence.last.fetch("summary")
    assert_equal "project", record.evidence.last.dig("retention", "policy")
    assert_equal "none", record.evidence.last.dig("retention", "enforcement")
    assert record.to_h.frozen? == false
    assert_raises(FrozenError) { record.data["revision"].replace("changed") }
  end

  def test_rejects_controls_unsafe_links_and_parent_traversal
    base = build_attributes

    error = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::Record.build(**base.merge(proposed_change: "escape\e[31m"))
    end
    assert_match(/control character/, error.message)

    error = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::Record.build(
        **base.merge(evidence: [ evidence.merge("source_ref" => "javascript:alert(1)") ])
      )
    end
    assert_match(/scheme/, error.message)

    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::Record.build(**base.merge(subject_ref: "../secrets"))
    end
  end

  def test_round_trips_only_the_closed_schema
    record = Hive::Proposals::Record.build(**build_attributes)
    assert_equal record.to_h, Hive::Proposals::Record.new(record.to_h).to_h

    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::Record.new(record.to_h.merge("surprise" => true))
    end
  end

  def test_persisted_policy_keeps_admitted_evidence_references_replayable
    attributes = build_attributes
    attributes[:policy] = attributes.fetch(:policy).merge(
      "allowed_link_schemes" => %w[git https]
    )
    attributes[:evidence] = [ evidence.merge("source_ref" => "git://example.test/results") ]
    record = Hive::Proposals::Record.build(**attributes)

    assert_equal %w[git https], record.policy.fetch("allowed_link_schemes")
    assert_equal record.to_h, Hive::Proposals::Record.new(record.to_h).to_h
  end

  private

  def build_attributes
    {
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      subject_kind: "workflow",
      subject_ref: "coding",
      revision: "v2",
      proposed_change: "Change the review stage",
      motivation: "Reduce false negatives",
      evidence: [ evidence ],
      author: author,
      provenance: provenance,
      source_event_id: "pse-#{'a' * 64}",
      created_at: "2026-08-30T12:00:00Z",
      policy: {
        "visibility" => "project", "retention" => "project",
        "allowed_link_schemes" => [ "https" ]
      }
    }
  end

  def evidence
    {
      "label" => "benchmark",
      "content" => "score=0.8",
      "visibility" => "project",
      "retention" => "task",
      "media_type" => "text/plain",
      "source_ref" => "https://example.test/result"
    }
  end

  def author
    { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" }
  end

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end
end
