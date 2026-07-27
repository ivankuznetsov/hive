# Recovery

## Diagnose before changing state

Start with native evidence:

```bash
hive status --operational --json
hive daemon status --json
hive status --diagnose SLUG --project PROJECT --json
```

Use the operational row’s liveness, reasons, scheduler freshness, provider hold, condition warning, and diagnostic artifact. Do not infer ownership from a process-name scan, and do not create a polling or repair script beside Hive.

Preserve the task folder, worktree, attempt records, queue entries, locks, markers, and daemon snapshots while investigating. A stale physical lock, a stale durable attempt, and a provider or global-cap wait are different conditions.

## Respect recovery ownership

- A provider reset hint is display evidence, not an embargo. Hive schedules the
  next readiness attempt from the marker mtime plus the shared cooldown.
- A verified live worker is running. Observe it; do not kill or redispatch it.
- Every persisted `ERROR` and `REVIEW_ERROR` is eligible for the same unbounded
  cooled retry when global and project retry gates are enabled. There is no
  retry budget to exhaust.
- `StaleAgentHealer` is the sole automatic scheduler. It submits the
  observation; `RecoveryCoordinator` alone persists the retry request, clears
  the exact marker generation, and dispatches the owning workflow command.
- A `retry_safety_blocked` row is deliberately parked. Repair the named current
  evidence (for example operator answers, dirty/foreign worktree state,
  unrestored controller files, or a credential still present locally); do not
  bypass it with a blind marker clear.
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

Use `hive status --json` only when detailed compatibility evidence such as marker attributes is needed. Prefer the operational contract for owner and reason classification.

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
