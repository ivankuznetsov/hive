# Merge main into opencode benchmark runtime follow-up

Merged `main` (unified Patrol Fix workflow, #1166) into
`fix/opencode-benchmark-runtime-followup`. Two files conflicted; both were
additive on each side.

- `lib/hive/stages/base.rb` — `main` rebound the post-run task through
  `task_after_controller_move` so a Patrol Fix route mutation cannot make the
  exit path dereference a vanished folder, changing `enforce_clean_exit!` to
  take `event_task`. This branch had added the auto-committed execute-residue
  reconciliation right after that call. Kept both: the enforce call and the
  reconciliation now both take `event_task`. For `4-execute` (the only stage
  the reconciliation runs on, and a coding-workflow stage) `event_task` is
  the unchanged `task`, so the promotion boundary is unaffected. `main`'s
  `task_after_controller_move` / `task_after_controller_exception` helpers and
  this branch's `reconcile_auto_committed_execute_residue` coexist.
- `wiki/gaps.md` — `main` rewrote the "Patrol Fix has no interrupted-attempt
  recovery" gap (the `Fixer` engines it described are gone) and appended an
  open-pr documentation gap. Took `main`'s text and re-appended this branch's
  "Benchmark-only plan-review opt-out live parity proven" section.

See [[stages/execute]], [[modules/patrol]].
