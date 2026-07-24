## [2026-07-24T12:41:43Z] daemon - harden universal retry across crashes and unsafe state

**Behavior:** Universal `ERROR` / `REVIEW_ERROR` retry now preserves the
failed request result only for that request id; a later request creates a
fresh attempt. Resolved lost ancestors no longer block successors, and orphan
cleanup is paced by the shared cooldown and honors global/project retry
enablement.

`3-plan` recovery durably enqueues an identity-bound continuation before
clearing its exact marker. The consumer verifies project, task id, stage,
marker identity, and predicted post-clear task generation, so crashes and
task-folder reuse cannot lose or misdeliver work. Config reload constructs the
full replacement state before publishing any of it.

Protected controller files are captured before agent phases and atomically
restored on tamper, including `handoff.yml` and review completion artifacts.
Retry safety blocks only when restoration failed, a credential is still
present, or a persisted worktree pointer cannot prove the expected path,
branch, registration, and repository ownership. Open-PR and finalize re-run
secret scans before mutation.

Operational status now distinguishes cooldown, in-flight, and safety-blocked
retry states and exposes the exact retry deadline and safety reason. Marker
clears take the task lock, closing the post-snapshot replacement race.

**Tests:** Added focused regression coverage for request-scoped attempt replay,
queue crash windows and generation binding, transactional reload, retry
deadlines and ownership, protected-file restoration, secret rechecks,
worktree-pointer forgery, project opt-outs, orphan pacing, and marker
replacement races.
