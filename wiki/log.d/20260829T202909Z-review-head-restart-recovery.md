# 2026-08-29 — Review-head restart recovery

`fix-success-NN.md` now binds a completed review pass to its exact worktree
HEAD. If a daemon restart lands after CI-fix commits but before the required
fresh reviewer pass, the next run reopens that pass instead of manufacturing
`REVIEW_STALE`; an interrupted widened pass resumes in place, while a matching
completed HEAD resumes at the browser gate. Legacy unbound sentinels receive
one conservative fresh pass.

The stale-agent healer now submits every automatically recoverable review
marker through `RecoveryCoordinator`, including `REVIEW_CI_STALE` and a
max-pass `REVIEW_STALE` whose fix-success receipt is at least as new as its
escalation artifact. A missing receipt or newer escalation remains a genuine
operator boundary.
