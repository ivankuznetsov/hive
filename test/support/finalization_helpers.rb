require "json"
require "securerandom"
require "hive/attempts/context"
require "hive/attempts/store"
require "hive/babysitter/job_store"
require "hive/finalization/reconciler"
require "hive/task_journal/envelope"
require "hive/worktree"

module HiveFinalizationTestHelper
  FINALIZATION_TEST_NOW = Time.utc(2026, 7, 17, 17, 0, 0)

  def with_finalize_attempt(task_folder:, attempt_id: nil, task_generation: 1)
    task = Hive::Task.new(task_folder)
    attempt_id ||= "finalize-test-#{SecureRandom.hex(8)}"
    ownership_generation = "owner-#{attempt_id}"
    store = Hive::Attempts::Store.new
    store.create_launching(
      attempt_id: attempt_id, request_id: "request-#{attempt_id}", predecessor_attempt_id: nil,
      task_id: task.id || task.slug, project: File.basename(task.project_root), task_slug: task.slug,
      intended_stage: "8-finalize", task_generation: ownership_generation,
      ownership_generation: ownership_generation, task_input_epoch: task_generation,
      progress_token: "progress", provider: "codex", starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
    )
    Hive::Attempts::Context.with(
      attempt_id: attempt_id, task_generation: task_generation,
      ownership_generation: ownership_generation
    ) { yield }
  end

  def prepare_archive_ready(project_root:, task_folder:, slug:, branch: slug,
                            task_generation: 1, now: FINALIZATION_TEST_NOW,
                            release_claim: true)
    FileUtils.mkdir_p(task_folder)
    store = Hive::Babysitter::JobStore.new(project_root: project_root, clock: -> { now })
    job = store.reserve!(
      project: File.basename(project_root), task_id: "42", task_slug: slug,
      task_generation: task_generation, repository: "github.com/acme/demo", pr_number: 42,
      pr_url: "https://github.com/acme/demo/pull/42", branch: branch,
      head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: "attempt-1",
      task_folder: task_folder, now: now
    )
    coordinates = {
      "job_id" => job.fetch("job_id"), "repository" => "github.com/acme/demo",
      "pr_number" => 42, "pr_url" => "https://github.com/acme/demo/pull/42",
      "head_sha" => "a" * 40, "head_generation" => 1,
      "finalize_attempt_id" => "attempt-1"
    }
    base = {
      occurred_at: now.iso8601(6), observed_at: now.iso8601(6),
      task: { "id" => "42", "slug" => slug }, workflow: "coding", stage: "8-finalize",
      attempt_id: "attempt-1", task_generation: task_generation,
      ownership_generation: "owner-1", evidence: [], provenance: { "source" => "test" }
    }
    events = [
      Hive::TaskJournal::Envelope.authoritative(base.merge(
        event_type: "finalized", event_id: "#{job.fetch('job_id')}:finalized", reason: "handoff",
        producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }, payload: coordinates
      )),
      Hive::TaskJournal::Envelope.authoritative(base.merge(
        event_type: "merged", event_id: "#{job.fetch('job_id')}:merged", reason: "explicit merged snapshot",
        producer: { "kind" => "babysitter_job", "job_id" => job.fetch("job_id"), "claim_fence" => 1 },
        payload: coordinates.merge("merged_at" => now.iso8601)
      ))
    ]
    File.write(File.join(task_folder, "events.jsonl"), events.map { |event| JSON.generate(event) }.join("\n") + "\n")
    store.activate!(job.fetch("job_id"), handoff_event_id: events.first.fetch("event_id"),
                    finalize_attempt_id: "attempt-1", now: now)
    token = store.claim!(job.fetch("job_id"), owner: "test-daemon", now: now, lease_sec: 300)
    store.mark_terminal!(token, now: now)
    store.release!(token, outcome: "merged", now: now) if release_claim
    Hive::Finalization::Reconciler.new(task_folder: task_folder, clock: -> { now }).reconcile
    File.write(
      File.join(task_folder, "worktree.yml"),
      { "path" => File.join(Hive::Worktree.canonical_root(project_root), slug),
        "branch" => branch, "created_at" => now.iso8601 }.to_yaml
    )
    { store: store, job: store.read(job.fetch("job_id")), token: token, coordinates: coordinates }
  end
end
