# Recovery

## Runtime cutover recovery

A `fleet_cutover_required` error is a controller-wide maintenance fence, not a
task retry. Run the read-only `hive runtime status --json` first and report its
`phase`, database status, `runtime_code`, and `next_action`. Do not run ordinary
workflow commands while the fence is active.

The SQLite cutover is irreversible. `hive migrate --all --yes` starts it and
`hive runtime resume` advances an interrupted cutover; both change controller
state and require explicit operator approval. There is no rollback, restore, or
downgrade path. Never invent one or remove cutover evidence. After an approved
resume, re-run `hive runtime status --json` and require `phase: active` with an
`ok` database before returning to task operations.

## Diagnose before changing state

Start with native evidence:

```bash
hive status --operational --json
hive daemon status --json
hive status --diagnose SLUG --project PROJECT --json
```

Use the operational row’s liveness, reasons, scheduler freshness, provider hold, condition warning, and diagnostic artifact. Do not infer ownership from a process-name scan, and do not create a polling or repair script beside Hive.

Preserve the task folder, worktree, attempt records, queue entries, locks, markers, and daemon snapshots while investigating. A stale physical lock, a stale durable attempt, and a provider or global-cap wait are different conditions.

## Keep task-history recovery separate from workflow retry

An operational row with `task_history_invalid: true` and reason
`condition_task_history_invalid` is synthetic and operator-owned. Hive could
not fold that task's authoritative `task-journal.jsonl`. This is not a persisted
workflow failure, so `workflow.retry`, marker clearing, rerunning the stage, or
restarting the daemon cannot repair it. Preserve the task folder, inspect the
task-local journal diagnostic, and recover the JSONL only from verified task
evidence or a trusted backup with explicit operator approval. Hive does not
synthesize missing history and has no projection repair command. Refresh
`hive status --operational --json` afterward. Hive isolates the row and
continues unrelated work automatically.

## Respect recovery ownership

- A provider reset hint is display evidence, not an embargo. Hive schedules the
  next readiness attempt from the marker mtime plus the shared cooldown.
- A verified live worker is running. Observe it; do not kill or redispatch it.
- Every persisted `ERROR` and `REVIEW_ERROR` is eligible for the same unbounded
  cooled retry when global and project retry gates are enabled. There is no
  retry budget to exhaust, except the exact `terminal_outcome_blocked` and
  `terminal_outcome_invalid` reasons. Those two remain durable and
  operator-owned: refresh operational status, then invoke its guarded
  `workflow.retry` action explicitly. If the diagnostic identifies a blocker
  propagated from an already-completed stage, create a fresh task instead.
- `StaleAgentHealer` is the sole automatic scheduler. It submits the
  observation; `RecoveryCoordinator` alone persists the retry request, clears
  the exact marker generation, and dispatches the owning workflow command.
- A `retry_safety_blocked` row is deliberately parked. Repair the named current
  evidence (for example operator answers, dirty/foreign worktree state,
  unrestored controller files, or a credential still present locally); do not
  bypass it with a blind marker clear.
- For `ensure_clean_on_exit_failed` or `dirty_worktree`, keep recovery inside
  Hive's owned-worktree boundary: inspect with
  `hive worktree status SLUG --json`, then use either
  `hive worktree commit-residue SLUG --json` or
  `hive worktree discard-residue SLUG --paths PATH [PATH ...] --json`.
  These commands are marker-gated, task-locked, and preserve the marker. After
  the repair, refresh `hive status --operational --json` and invoke only the fresh
  generation-guarded `workflow.retry` action it emits.
- If the daemon is not running and background automation is expected,
  `hive daemon start --detach` is the normal start form.
- `recovery_migration_required` means the current failure predates marker IDs.
  Run `hive migrate PROJECT_PATH` once; do not synthesize an identity from
  reason, mtime, or another marker attr.

Keep these commonly confused cases separate:

- `REVIEW_ERROR phase=fix reason=fix_failed` with a Claude stop-hook completion
  failure uses the same universal retry path as other review errors. The stage
  re-runs its ordinary completion and integrity checks.
- `limits_reached` is scheduler-owned even when `retry_after` is missing or
  malformed; the shared marker-age cooldown remains authoritative.
- Stale `agent_working` with a verified live PID/lock is still running. An
  orphan may be healer-managed; a dead worker rewritten to
  `ERROR reason=agent_died` enters the universal cooled retry path.
- Tamper errors retry only after Hive reports `restored=true`. Worktree-bearing
  stages also revalidate the exact task path, slug branch, Git worktree
  registration, and repository identity before retry.
- Secret-related errors remain safety-blocked while a credential pattern is
  present in the local PR source; open-PR/finalize re-entry also scans the
  current remote body before any new publication.

Use `hive task TARGET --project PROJECT --json` for one task's detailed
evidence. Use the operational contract for owner and reason classification.

## Use the native recovery action

For an operational row with a fresh routine `workflow.retry` descriptor, use
the exact action and observation token from that same snapshot:

```bash
hive act workflow.retry PROJECT:SLUG --observation TOKEN --json
```

The receipt is canonical queued, cooldown, running, blocked, terminal, or
unavailable truth. Re-snapshot immediately. If the observed generation,
marker, or ownership changed, stop and diagnose the new state rather than
applying the old remedy.

Low-level `hive markers clear`, force advancement, queue pruning, stopping a
worker, or replacing recovery state bypasses or alters normal coordination.
Explain the exact observed reason and effect, then obtain explicit confirmation.
`hive markers clear` is an exceptional operator repair primitive, not a retry
recipe; never compose it with a stage run as another recovery mechanism.
