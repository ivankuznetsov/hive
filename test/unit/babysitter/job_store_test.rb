require "test_helper"
require "hive/babysitter/job_store"

class BabysitterJobStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 17, 14, 0, 0)

  def test_reservation_is_stable_inactive_and_unclaimable_until_journal_handoff
    with_store do |store, task_folder|
      first = reserve(store, task_folder)
      replay = reserve(store, task_folder, finalize_attempt_id: "attempt-2")

      assert_equal first.fetch("job_id"), replay.fetch("job_id")
      assert_equal "inactive", replay.fetch("state")
      assert_nil store.claim!(first.fetch("job_id"), owner: "daemon-a", now: T0)

      write_handoff(task_folder, first)
      active = store.activate!(
        first.fetch("job_id"), handoff_event_id: "finalized", finalize_attempt_id: "attempt-1", now: T0
      )
      assert_equal "active", active.fetch("state")
      assert_equal first.fetch("job_id"), store.current_job(task_slug: "durable-task", task_generation: 3).fetch("job_id")
    end
  end

  def test_startup_repair_activates_a_journal_backed_reservation
    with_store do |store, task_folder|
      job = reserve(store, task_folder)
      write_handoff(task_folder, job)

      repaired = store.repair_activations!(now: T0)

      assert_equal [ job.fetch("job_id") ], repaired.map { |entry| entry.fetch("job_id") }
      assert_equal "active", store.read(job.fetch("job_id")).fetch("state")
    end
  end

  def test_claim_takeover_advances_fence_and_rejects_late_owner
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      first = store.claim!(job.fetch("job_id"), owner: "daemon-a", now: T0, lease_sec: 30)
      assert_equal 1, first.fetch("claim_fence")
      assert_nil store.claim!(job.fetch("job_id"), owner: "daemon-b", now: T0 + 10)

      second = store.claim!(
        job.fetch("job_id"), owner: "daemon-b", now: T0 + 31, lease_sec: 30,
        claim_resolver: ->(_claim) { :resolved }
      )
      assert_equal 2, second.fetch("claim_fence")
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.authorize!(first, expected_sha: "a" * 40, head_generation: 1, now: T0 + 32)
      end
      assert store.authorize!(second, expected_sha: "a" * 40, head_generation: 1, now: T0 + 32)
    end
  end

  def test_replacement_requires_exact_closed_or_invalid_proof_and_preserves_history
    with_store do |store, task_folder|
      old = activate(store, task_folder)
      assert_raises(Hive::Babysitter::JobStore::ReplacementBlocked) do
        reserve(store, task_folder, pr_number: 13, replace: old, remote_state: "OPEN")
      end

      replacement = reserve(store, task_folder, pr_number: 13, replace: old, remote_state: "CLOSED")

      assert_equal "superseded", store.read(old.fetch("job_id")).fetch("state")
      assert_equal "inactive", replacement.fetch("state")
      assert_equal old.fetch("job_id"), replacement.fetch("supersedes_job_id")
      assert_equal replacement.fetch("job_id"),
                   store.current_job(task_slug: "durable-task", task_generation: 3).fetch("job_id")
    end
  end

  def test_corrupt_and_truncated_records_fail_closed_without_rewrite
    with_store do |store, task_folder|
      job = reserve(store, task_folder)
      path = store.job_path(job.fetch("job_id"))
      File.binwrite(path, "{")
      before = File.binread(path)

      assert_raises(Hive::Babysitter::JobStore::CorruptRecord) { store.read(job.fetch("job_id")) }
      assert_equal before, File.binread(path)
    end
  end

  def test_journal_writer_rejects_a_stale_claim_fence
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      first = store.claim!(job.fetch("job_id"), owner: "daemon-a", now: T0, lease_sec: 30)
      store.claim!(
        job.fetch("job_id"), owner: "daemon-b", now: T0 + 31, lease_sec: 30,
        claim_resolver: ->(_claim) { :resolved }
      )
      writer = Hive::TaskJournal::Writer.new(
        task_folder: task_folder, authority_validator: store, clock: -> { T0 + 32 }
      )
      coordinates = {
        "job_id" => job.fetch("job_id"), "repository" => "github.com/acme/demo",
        "pr_number" => 12, "pr_url" => "https://github.com/acme/demo/pull/12",
        "head_sha" => "a" * 40, "head_generation" => 1,
        "finalize_attempt_id" => "attempt-1"
      }
      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        writer.append_once(
          event_id: "stale-active", event_type: "babysitter_active", occurred_at: (T0 + 32).iso8601(6),
          observed_at: (T0 + 32).iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
          workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
          ownership_generation: "owner-1", reason: "claimed", evidence: [],
          provenance: { "source" => "test" },
          producer: { "kind" => "babysitter_job", "job_id" => job.fetch("job_id"),
                      "claim_fence" => first.fetch("claim_fence") }, payload: coordinates
        )
      end
      assert_includes error.message, "stale"
    end
  end

  private

  def with_store
    with_tmp_dir do |project|
      task_folder = File.join(project, ".hive-state", "stages", "8-finalize", "durable-task")
      FileUtils.mkdir_p(task_folder)
      yield Hive::Babysitter::JobStore.new(project_root: project, clock: -> { T0 + 32 }), task_folder
    end
  end

  def reserve(store, task_folder, finalize_attempt_id: "attempt-1", pr_number: 12,
              replace: nil, remote_state: nil)
    attributes = {
      project: "demo", task_id: 42, task_slug: "durable-task", task_generation: 3,
      repository: "https://github.com/acme/demo", pr_number: pr_number,
      pr_url: "https://github.com/acme/demo/pull/#{pr_number}", branch: "feature/durable",
      head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: finalize_attempt_id,
      task_folder: task_folder, now: T0
    }
    return store.reserve!(**attributes) unless replace

    store.reserve_replacement!(
      old_job_id: replace.fetch("job_id"), remote_state: remote_state,
      remote_observed_at: T0.iso8601, **attributes
    )
  end

  def activate(store, task_folder)
    job = reserve(store, task_folder)
    write_handoff(task_folder, job)
    store.activate!(job.fetch("job_id"), handoff_event_id: "finalized",
                    finalize_attempt_id: "attempt-1", now: T0)
  end

  def write_handoff(task_folder, job)
    payload = {
      "job_id" => job.fetch("job_id"), "repository" => "github.com/acme/demo",
      "pr_number" => 12, "pr_url" => "https://github.com/acme/demo/pull/12",
      "head_sha" => "a" * 40, "head_generation" => 1,
      "finalize_attempt_id" => "attempt-1"
    }
    event = Hive::TaskJournal::Envelope.authoritative({
      event_type: "finalized", event_id: "finalized", occurred_at: T0.iso8601(6),
      observed_at: T0.iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-1", reason: "handoff", evidence: [],
      provenance: { "source" => "test" },
      producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }, payload: payload
    })
    File.write(File.join(task_folder, "events.jsonl"), "#{JSON.generate(event)}\n")
  end
end
