require "hive/attempts/supervisor"
require "hive/attempts/reconciler"

module RuntimeContentionAttemptFixture
  SECRET = "c" * 64

  def create_contention_attempt(store, id:, now: Time.now.utc, worker: [ "/bin/true" ])
    store.create_launching(
      attempt_id: id, request_id: "request-#{id}", task_id: id,
      project: "contention", task_slug: "task-#{id}", intended_stage: "4-execute",
      task_generation: "generation", progress_token: "progress-#{id}", provider: "codex",
      worker_argv: worker, claim_capability_digest: Hive::Attempts::Capability.digest(SECRET),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: now
    )
  end
end
