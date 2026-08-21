# Plan revision isolates provider custody from Hive bookkeeping

Planner revision previously captured its ArtifactFirewall manifest outside the
shared agent launcher. The launcher records durable session start and finish
activity in `task-journal.jsonl` and rebuilds `task-projection.json`, so a
successful planner that produced a valid candidate could be reported as having
tampered with those two controller-owned files. Hive restored its own writes,
discarded the candidate, and terminalized mandatory review.

`PlannerRevision::HiveRunner` now passes an `AgentCustody` object into
`Stages::Base.spawn_agent`. The shared launcher starts custody immediately
around the provider process and closes it before usage, context, and session
finish bookkeeping. The full protected-anchor set remains covered during the
untrusted interval, candidate output remains required and shape-checked, and a
successful launcher that never invokes custody fails closed.

The same recovery path now includes `planner_revision` alongside primary,
adversarial, and verification routes. A terminal planner-revision failure can
therefore receive the documented observation-bound `request-review` reset
instead of leaving a mandatory review permanently parked with no valid action.

Focused tests reproduce controller journal/projection writes on both sides of
the provider interval, retain provider-tamper detection and restoration, cover
missing custody, and preserve complete-candidate timeout salvage.
