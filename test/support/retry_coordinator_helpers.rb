module RetryCoordinatorTestHelpers
  def create_failed_retry_attempt(store, id:, now:, project: "demo", slug: "durable-task",
                                  stage: "4-execute", generation: 3,
                                  ownership_generation: "ownership-1")
    launching = store.create_launching(
      attempt_id: id, request_id: "request-#{id}", predecessor_attempt_id: nil,
      task_id: "42", project: project, task_slug: slug, intended_stage: stage,
      task_generation: ownership_generation, ownership_generation: ownership_generation,
      task_input_epoch: generation, progress_token: "progress", provider: "codex",
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: now
    )
    claimed = store.claim(
      launching,
      owner: {
        "pid" => Process.pid, "start_fingerprint" => "pid-start",
        "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
      },
      first_heartbeat_timeout_sec: 30, now: now + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: now + 2)
    store.terminalize(
      running, outcome: "failed", exit_status: 1,
      final_checkpoint: { "revision" => "a" * 40, "progress_token" => "progress" },
      output_references: [],
      log_reference: { "path" => "logs/#{id}.frames", "size" => 0, "sha256" => "0" * 64 },
      now: now + 3
    )
  end

  def retry_failure_args(attempt, code:, terminal_event_id:, evidence: nil)
    {
      project: attempt["project"],
      task: { "id" => attempt["task_id"], "slug" => attempt["task_slug"] },
      workflow: "coding", stage: attempt["intended_stage"],
      generation: attempt.task_input_epoch,
      ownership_generation: attempt.ownership_generation,
      attempt_id: attempt.attempt_id, terminal_event_id: terminal_event_id,
      failure_class: code, code: code,
      evidence: evidence || [ { "field" => "message", "value" => "terminal failure" } ],
      guidance: "Repair the terminal condition."
    }
  end
end
