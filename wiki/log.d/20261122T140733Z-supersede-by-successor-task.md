## 2026-11-22 — Superseded closure can rest on its successor task alone

- Request: the operator tried to close a task as superseded by another Hive
  task (a Rails port that replaces it). Hive refused because superseded
  closure demanded merged-PR or commit evidence.
- Change: `hive archive TASK --reason superseded --successor project:slug
  --attestation "..."` works with no `--evidence`. The registered successor is
  the proof, and the authority is `operator_attestation`. With `--evidence`,
  verification is unchanged, including the cross-repository rules, and
  unverifiable evidence never falls back to the successor alone.
- New `Hive::TaskClosure.undelivered?(reason, evidence)`: cancellation, or
  supersession without evidence. Undelivered closure binds the registered
  checkout (`task_repository: {path}`, no GitHub access), skips the
  owned-worktree delivery blockers so the worktree and branch stay for the
  successor, records `COMPLETE outcome=superseded` instead of running the
  terminal stage, and is revalidated the same way on resume and at the final
  locked guard.
- Successor rule: besides self-reference and unresolvable successors, preview
  refuses a successor that was cancelled (`successor/cancelled`), was itself
  superseded without delivery (`successor/superseded`, which also refuses
  supersession cycles), or has an unreadable closure receipt
  (`successor/closure_invalid`). An active successor, or one archived with
  delivery, qualifies.
- Dependency admission: `DependencyAdmission::TaskSnapshot` gains
  `superseded_by` (default nil). A prerequisite superseded without delivery
  fails admission with a correction to depend on the successor, as a
  cancelled prerequisite does.
- `hive-task-closure.v1` receipt schema accepts the new shape (superseded,
  empty evidence, path repository, successor object, attestation). Existing
  receipts remain valid; no version bump.
- Surfaces: `hive help archive` lists per-reason requirements with a
  superseded-by-task example; the bot `/close` no longer demands `--evidence`
  for superseded but requires `--successor`, and its preview names the
  successor; the Web preview and task page show the successor; the
  not-merged archive refusal mentions `--successor`.
- Pages: [[commands/stage_action]], [[commands/bot]], [[state-model]],
  [[stages/done]], [[modules/task_dependencies]], [[cli]], [[gaps]].
