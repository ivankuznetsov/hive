require "test_helper"
require "hive/proposals/source_event_store"

class ProposalSourceEventStoreTest < Minitest::Test
  include HiveTestHelper

  def test_admits_immutable_receipts_tracks_only_pending_ids_and_is_idempotent
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      event = source_event

      result = store.admit!(event)
      replay = store.admit!(event)

      assert_equal event.source_event_id, result.source_event_id
      assert_equal result.to_h, replay.to_h
      assert_equal [ event.source_event_id ], store.pending_ids
      assert_equal event.to_h, store.fetch(event.source_event_id).to_h

      store.mark_consumed!(event.source_event_id, result: { "proposal_id" => event.proposal_id })

      assert_empty store.pending_ids
      assert_equal "consumed", store.status(event.source_event_id).fetch("state")
      assert_equal 1, store.index.fetch("consumed_count")
    end
  end

  def test_conflicts_on_changed_replay_and_fails_quota_before_a_second_receipt
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_pending_sources" => 1)
      )
      store.admit!(source_event)

      changed = Hive::Proposals::SourceEvent.new(
        source_event.to_h.merge("created_at" => "2026-08-30T12:00:01.000000Z")
      )
      assert_raises(Hive::Proposals::Conflict) { store.admit!(changed) }

      second = Hive::Proposals::SourceEvent.new(
        source_event.to_h.merge("source_event_id" => "pse-#{'d' * 64}")
      )
      assert_raises(Hive::Proposals::QuotaExceeded) { store.admit!(second) }
      assert_equal [ source_event.source_event_id ], store.pending_ids
    end
  end

  def test_enforces_the_per_proposal_event_ceiling_after_consumption
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_proposal_events" => 1)
      )
      store.admit!(source_event)
      store.mark_consumed!(
        source_event.source_event_id,
        result: {
          "kind" => "record", "proposal_id" => source_event.proposal_id,
          "event_id" => nil, "source_event_id" => source_event.source_event_id
        }
      )
      second = Hive::Proposals::SourceEvent.new(
        source_event.to_h.merge("source_event_id" => "pse-#{'d' * 64}")
      )

      assert_raises(Hive::Proposals::QuotaExceeded) { store.admit!(second) }
      assert_empty store.pending_ids
      assert_equal 1, store.index.dig("proposal_usage", source_event.proposal_id, "sources")
    end
  end

  private

  def source_event
    @source_event ||= Hive::Proposals::SourceEvent.submission(
      source_event_id: "pse-#{'a' * 64}",
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      proposal_binding: {
        "schema_version" => 1,
        "subject" => {
          "kind" => "workflow", "reference" => "coding", "revision" => "v2",
          "proposal_id" => "prp-00000000-0000-4000-8000-000000000001"
        },
        "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:workflow" },
        "evaluator" => nil, "configuration_fingerprint" => "c" * 64,
        "policy" => {
          "visibility" => "project", "retention" => "project",
          "allowed_link_schemes" => [ "https" ]
        }
      },
      task_binding: {
        "project" => "hive", "task_id" => "43059", "task_slug" => "proposal-task",
        "workflow_id" => "coding", "stage" => "4-execute", "task_generation" => 1,
        "ownership_generation" => "owner-1", "attempt_id" => "attempt-1"
      },
      proposed_change: "Change review", motivation: "Improve quality",
      evidence: [ { "label" => "test", "content" => "pass", "media_type" => "text/plain" } ],
      created_at: "2026-08-30T12:00:00Z"
    )
  end

  def limits
    {
      "max_pending_sources" => 8, "max_project_events" => 100,
      "max_project_bytes" => 1_000_000, "max_sources_per_actor_per_hour" => 10
    }
  end
end
