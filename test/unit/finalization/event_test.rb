require "test_helper"
require "hive/finalization/event"

class FinalizationEventTest < Minitest::Test
  NOW = Time.utc(2026, 7, 17, 13, 0, 0)

  def test_closed_event_and_producer_vocabularies_are_enforced
    event = build(:finalized)
    assert Hive::Finalization::Event.validate!(event, records: [])

    unknown_type = event.merge("event_type" => "github_green")
    assert_raises(Hive::Finalization::InvalidEvent) do
      Hive::Finalization::Event.validate!(unknown_type, records: [])
    end

    unknown_producer = event.merge("producer" => { "kind" => "daemon" })
    assert_raises(Hive::Finalization::InvalidProducer) do
      Hive::Finalization::Event.validate!(unknown_producer, records: [])
    end
  end

  def test_attempt_adoption_preserves_same_head_and_rejects_retargeting
    finalized = build(:finalized)
    adopted = build(
      :finalize_attempt_adopted,
      event_id: "adopted",
      attempt_id: "attempt-2",
      producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-2" }
    )
    assert Hive::Finalization::Event.validate!(adopted, records: [ finalized ])

    changed_head = adopted.merge(
      "event_id" => "bad-adoption",
      "payload" => adopted.fetch("payload").merge("head_sha" => "b" * 40)
    )
    error = assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate!(changed_head, records: [ finalized ])
    end
    assert_includes error.message, "head_sha"
  end

  def test_head_supersession_requires_the_next_generation_and_a_new_sha
    finalized = build(:finalized)
    valid = build(
      :head_superseded,
      event_id: "head-2",
      producer: babysitter_producer,
      payload: coordinates.merge("head_sha" => "b" * 40, "head_generation" => 2)
    )
    assert Hive::Finalization::Event.validate!(valid, records: [ finalized ])

    stale = valid.merge(
      "event_id" => "stale-head",
      "payload" => valid.fetch("payload").merge("head_generation" => 1)
    )
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate!(stale, records: [ finalized ])
    end
  end

  def test_archive_ready_requires_reconciler_and_current_terminal_event
    finalized = build(:finalized)
    merged = build(
      :merged,
      event_id: "merged",
      producer: babysitter_producer,
      payload: coordinates.merge("merged_at" => NOW.iso8601)
    )
    archive = build(
      :archive_ready,
      event_id: "archive-ready",
      producer: { "kind" => "reconciler", "name" => "hive-finalization-reconciler-v1" },
      payload: coordinates.merge("terminal_event_id" => "merged")
    )
    assert Hive::Finalization::Event.validate!(archive, records: [ finalized, merged ])

    wrong_producer = archive.merge("producer" => babysitter_producer)
    assert_raises(Hive::Finalization::InvalidProducer) do
      Hive::Finalization::Event.validate!(wrong_producer, records: [ finalized, merged ])
    end

    stale_terminal = archive.merge(
      "event_id" => "bad-archive",
      "payload" => archive.fetch("payload").merge("terminal_event_id" => "missing")
    )
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate!(stale_terminal, records: [ finalized, merged ])
    end
  end

  private

  def build(type, event_id: type.to_s, attempt_id: "attempt-1", producer: nil, payload: nil)
    producer ||= if type == :finalized || type == :finalize_attempt_adopted
      { "kind" => "finalize_attempt", "attempt_id" => attempt_id }
    else
      babysitter_producer
    end
    Hive::TaskJournal::Envelope.authoritative({
      event_type: type.to_s,
      event_id: event_id,
      occurred_at: NOW.iso8601(6),
      observed_at: NOW.iso8601(6),
      task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding",
      stage: "8-finalize",
      attempt_id: attempt_id,
      task_generation: 3,
      ownership_generation: "ownership-1",
      commit_generation: nil,
      reason: type.to_s,
      evidence: [],
      provenance: { "source" => "test" },
      producer: producer,
      payload: payload || coordinates.merge("finalize_attempt_id" => attempt_id)
    })
  end

  def coordinates
    {
      "job_id" => "job-1",
      "repository" => "github.com/acme/demo",
      "pr_number" => 12,
      "pr_url" => "https://github.com/acme/demo/pull/12",
      "head_sha" => "a" * 40,
      "head_generation" => 1,
      "finalize_attempt_id" => "attempt-1"
    }
  end

  def babysitter_producer
    { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 4 }
  end
end
