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

## Respect healer ownership

- A current provider hold with a valid `retry_after` is a wait. Let the scheduler retry after the hold; do not clear it to force a provider call.
- A verified live worker is running. Observe it; do not kill or redispatch it.
- A stale or dead worker classified `needs_repair` requires the reason-specific recovery path. Do not assume every stale marker is auto-requeued.
- Known bounded healer cases should remain with the healer while its retry budget remains. If the daemon is not running and background automation is expected, `hive daemon start --detach` is the normal start form.
- Exhausted recovery, malformed hold data, foreign worktree state, and terminal manual errors require operator judgment.

Keep these commonly confused cases separate:

- `REVIEW_ERROR phase=fix reason=fix_failed` with a Claude stop-hook completion
  failure can be healer-managed while its bounded retry budget remains. Other
  `fix_failed` reasons require diagnosis instead of a blind clear.
- `limits_reached` with a valid `retry_after` is scheduler-owned. A missing or
  malformed retry timestamp needs repair evidence, not a forced provider call.
- Stale `agent_working` with a verified live PID/lock is still running. An
  orphan may be healer-managed; a dead worker rewritten to
  `ERROR reason=agent_died` is a manual recovery condition.
- A terminal/manual `ERROR` remains operator-owned until its reason is
  understood and the exact mutation is approved.

Use `hive status --json` only when detailed compatibility evidence such as marker attributes is needed. Prefer the operational contract for owner and reason classification.

## Guard manual recovery

Marker clearing, force advancement, queue pruning, stopping a worker, or replacing recovery state is mutation. Explain the exact observed reason and the effect, then obtain explicit confirmation. Prefer generation- or marker-id-bound guards printed by Hive, for example:

```bash
hive markers clear SLUG --project PROJECT --name REVIEW_ERROR --json
hive markers clear FOLDER --name ERROR --match-attr marker_id=MARKER_ID
```

Re-snapshot immediately after any confirmed recovery. If the observed generation, marker, or ownership changed, stop and diagnose the new state rather than applying the old remedy.
