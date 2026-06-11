---
date: 2026-06-11
slug: healer-plan-requeue
pages: [modules/daemon, gaps]
---

Dogfood incident #2 with the unmerged orphan-sweep fix (PR #446): a review
pass's old pkill sweep matched the tmux SERVER argv and killed it, taking a
parallel 3-plan agent down (`tmux_session_terminated`). The healer healed
the marker — and deadlocked: clearing the ERROR left an empty plan.md,
which `TaskAction#incomplete_plan_artifact?` classifies straight back to
`:error`, an action Policy skips and the healer can no longer match (no
marker reason left).

Fix: `StaleAgentHealer` 3-plan agent-loss heals now also enqueue
`hive plan <slug> --from 3-plan` through `DispatchRequestQueue`
(requestor=healer, logged as `heal_requeued`), so re-entry is explicit.
Other stages keep the passive edit-resume path — their state files
classify dispatchable once the marker clears. The queue's concurrency
gates and the heal retry budget (3) still bound the reruns.
