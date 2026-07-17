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

  def test_payload_and_handoff_are_required_before_lifecycle_events
    finalized = build(:finalized)
    assert_raises(Hive::Finalization::InvalidEvent) do
      Hive::Finalization::Event.validate!(finalized.merge("payload" => []), records: [])
    end
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate!(build(:merge_ready), records: [])
    end
  end

  def test_every_producer_identity_is_strictly_validated
    finalized = build(:finalized)
    cases = [
      [ finalized.merge("producer" => nil), Hive::Finalization::InvalidProducer ],
      [ finalized.merge("producer" => babysitter_producer), Hive::Finalization::InvalidProducer ],
      [ finalized.merge("producer" => { "kind" => "finalize_attempt", "attempt_id" => "other" }),
        Hive::Finalization::InvalidProducer ],
      [ build(:merge_ready, producer: { "kind" => "babysitter_job", "claim_fence" => 0 }),
        Hive::Finalization::InvalidEvent ],
      [ build(:archive_ready, producer: { "kind" => "reconciler", "name" => "other" }),
        Hive::Finalization::InvalidProducer ],
      [ build(:no_pr_approved, producer: { "kind" => "operator", "uid" => 1, "channel" => "local_tty" }),
        Hive::Finalization::InvalidEvent ],
      [ build(:no_pr_approved, producer: { "kind" => "operator", "uid" => 1, "login" => "me",
                                          "channel" => "api" }),
        Hive::Finalization::InvalidProducer ]
    ]

    cases.each do |record, error_class|
      assert_raises(error_class) { Hive::Finalization::Event.validate_producer!(record, record["event_type"]) }
    end
  end

  def test_coordinate_shape_rejects_missing_invalid_and_malformed_values
    [
      coordinates.reject { |key, _value| key == "job_id" },
      coordinates.merge("pr_number" => 0),
      coordinates.merge("head_generation" => 0),
      coordinates.merge("head_sha" => "not-a-sha")
    ].each do |payload|
      assert_raises(Hive::Finalization::InvalidEvent) do
        Hive::Finalization::Event.validate_coordinates!(payload)
      end
    end
  end

  def test_finalized_replay_requires_attempt_generation_or_valid_replacement
    current = Hive::Finalization::Projection.project(records: [ build(:finalized) ])
    wrong_attempt = build(:finalized, attempt_id: "attempt-2")
    wrong_attempt["payload"]["finalize_attempt_id"] = "attempt-1"
    assert_raises(Hive::Finalization::InvalidEvent) do
      Hive::Finalization::Event.validate_finalized!(wrong_attempt, wrong_attempt["payload"],
                                                    Hive::Finalization::Projection.empty_projection)
    end

    replay = build(:finalized, event_id: "duplicate")
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_finalized!(replay, replay["payload"], current)
    end

    newer = build(:finalized, event_id: "new-generation")
    newer["task_generation"] = 4
    assert Hive::Finalization::Event.validate_finalized!(newer, newer["payload"], current).nil?

    replacement = build(:finalized, event_id: "replacement")
    replacement["payload"] = replacement["payload"].merge(
      "job_id" => "job-2", "supersedes_job_id" => "job-1",
      "replacement_proof" => { "state" => "CLOSED" }
    )
    assert Hive::Finalization::Event.validate_finalized!(replacement, replacement["payload"], current).nil?
  end

  def test_stale_task_coordinates_attempts_heads_and_fences_are_rejected
    current = Hive::Finalization::Projection.project(records: [ build(:finalized) ])
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_task_generation!({ "task_generation" => 9 }, current)
    end
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_current_coordinates!(coordinates.merge("pr_number" => 99), current)
    end

    adopted = build(:finalize_attempt_adopted)
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_adoption!(adopted, adopted["producer"], adopted["payload"], current)
    end
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_head_supersession!(coordinates, current)
    end
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_claim_fence!({ "claim_fence" => 1 }, current.merge("claim_fence" => 2))
    end
  end

  def test_terminal_blocker_and_state_helpers_fail_closed
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_archive_ready!(
        { "terminal_event_id" => "missing" },
        Hive::Finalization::Projection.empty_projection.merge("state" => "finalized")
      )
    end
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate_archive_ready!(
        { "terminal_event_id" => "old" },
        Hive::Finalization::Projection.empty_projection.merge(
          "state" => "merged", "evidence" => { "terminal_event_id" => "new" }
        )
      )
    end
    assert_raises(Hive::Finalization::InvalidEvent) do
      Hive::Finalization::Event.validate_blocker!({ "code" => "", "needs_human" => true, "source" => "test" })
    end
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.require_state!({ "state" => "merged" }, [ "finalized" ], "merge_ready")
    end
  end

  def test_no_pr_cleanup_generation_and_adoption_edge_cases_fail_closed
    finalized = build(:finalized)
    bad_outcome = build(
      :no_pr_approved,
      producer: { "kind" => "operator", "uid" => 1, "login" => "tester", "channel" => "local_tty" },
      payload: coordinates.merge("outcome" => "label_done")
    )
    assert_raises(Hive::Finalization::InvalidEvent) do
      Hive::Finalization::Event.validate!(bad_outcome, records: [ finalized ])
    end

    merged = build(:merged, event_id: "merged", payload: coordinates.merge("merged_at" => NOW.iso8601))
    archive = build(
      :archive_ready, event_id: "archive",
      producer: { "kind" => "reconciler", "name" => "hive-finalization-reconciler-v1" },
      payload: coordinates.merge("terminal_event_id" => "merged")
    )
    cleanup = build(
      :cleanup_completed, event_id: "cleanup",
      producer: { "kind" => "reconciler", "name" => "hive-finalization-reconciler-v1" },
      payload: coordinates.merge("archive_ready_event_id" => "wrong")
    )
    assert_raises(Hive::Finalization::StaleEvidence) do
      Hive::Finalization::Event.validate!(cleanup, records: [ finalized, merged, archive ])
    end

    bad_fence = build(
      :merge_ready, producer: { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 0 }
    )
    assert_raises(Hive::Finalization::InvalidProducer) do
      Hive::Finalization::Event.validate_producer!(bad_fence, "merge_ready")
    end

    generation = build(:finalized)
    generation["payload"]["head_generation"] = 2
    assert_raises(Hive::Finalization::InvalidEvent) do
      Hive::Finalization::Event.validate_finalized!(
        generation, generation["payload"], Hive::Finalization::Projection.empty_projection
      )
    end

    adoption = build(:finalize_attempt_adopted, attempt_id: "attempt-2")
    assert_raises(Hive::Finalization::InvalidProducer) do
      Hive::Finalization::Event.validate_adoption!(
        adoption, { "attempt_id" => "attempt-3" }, adoption["payload"],
        Hive::Finalization::Projection.project(records: [ finalized ])
      )
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
