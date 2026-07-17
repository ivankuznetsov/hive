require "test_helper"
require "hive/finalization/reconciler"

class FinalizationReconcilerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 17, 0, 0)

  def test_only_current_explicit_merged_evidence_becomes_archive_ready_once
    with_tmp_dir do |dir|
      write_records(dir, [ event("finalized"), merged_event ])
      reconciler = Hive::Finalization::Reconciler.new(task_folder: dir, clock: -> { NOW })

      first = reconciler.reconcile
      second = reconciler.reconcile
      records = Hive::TaskProjection.read_journal(File.join(dir, "events.jsonl"))

      assert_equal :archive_ready, first.status
      assert_equal :already_ready, second.status
      assert_equal "archive_ready", second.projection.fetch("state")
      assert_equal 1, records.count { |record| record["event_type"] == "archive_ready" }
      assert_equal "merged", records.last.dig("payload", "terminal_event_id")
    end
  end

  def test_finalize_readiness_and_closed_unmerged_are_not_eligible
    [
      [ event("finalized") ],
      [ event("finalized"), event("babysitter_active", producer: babysitter),
        event("merge_ready", producer: babysitter) ],
      [ event("finalized"), event("babysitter_blocked", producer: babysitter,
                                  payload: coordinates.merge("blocker" => blocker)) ]
    ].each do |records|
      with_tmp_dir do |dir|
        write_records(dir, records)
        result = Hive::Finalization::Reconciler.new(task_folder: dir, clock: -> { NOW }).reconcile

        assert_equal :not_eligible, result.status
        refute Hive::TaskProjection.read_journal(File.join(dir, "events.jsonl"))
                                  .any? { |record| record["event_type"] == "archive_ready" }
      end
    end
  end

  def test_new_head_after_merged_invalidates_terminal_evidence
    records = [
      event("finalized"),
      merged_event,
      event("head_superseded", event_id: "head-2", producer: babysitter,
            payload: coordinates.merge("head_sha" => "b" * 40, "head_generation" => 2))
    ]
    with_tmp_dir do |dir|
      write_records(dir, records)
      result = Hive::Finalization::Reconciler.new(task_folder: dir, clock: -> { NOW }).reconcile

      assert_equal :not_eligible, result.status
      assert_equal "babysitter_active", result.projection.fetch("state")
    end
  end

  def test_tampered_finalization_history_fails_closed
    bad = event(
      "merged", producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" },
      payload: coordinates.merge("merged_at" => NOW.iso8601)
    )
    with_tmp_dir do |dir|
      write_records(dir, [ event("finalized"), bad ])

      assert_raises(Hive::Finalization::InvalidProducer) do
        Hive::Finalization::Reconciler.new(task_folder: dir, clock: -> { NOW }).reconcile
      end
    end
  end

  private

  def write_records(dir, records)
    File.write(File.join(dir, "events.jsonl"), records.map { |record| JSON.generate(record) }.join("\n") + "\n")
  end

  def merged_event
    event("merged", event_id: "merged", producer: babysitter,
          payload: coordinates.merge("merged_at" => NOW.iso8601))
  end

  def event(type, event_id: type, producer: nil, payload: coordinates)
    producer ||= { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }
    Hive::TaskJournal::Envelope.authoritative({
      event_type: type, event_id: event_id, occurred_at: NOW.iso8601(6),
      observed_at: NOW.iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-1", reason: type, evidence: [], provenance: { "source" => "test" },
      producer: producer, payload: payload
    })
  end

  def coordinates
    {
      "job_id" => "job-1", "repository" => "github.com/acme/demo", "pr_number" => 12,
      "pr_url" => "https://github.com/acme/demo/pull/12", "head_sha" => "a" * 40,
      "head_generation" => 1, "finalize_attempt_id" => "attempt-1"
    }
  end

  def babysitter
    { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 1 }
  end

  def blocker
    { "code" => "closed_unmerged", "needs_human" => true,
      "detail" => "closed without merge", "source" => "github" }
  end
end
