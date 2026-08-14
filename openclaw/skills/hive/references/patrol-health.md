# Patrol health

Use Hive's bounded read-only query surfaces. Do not parse `.hive-state/patrol`
or the Architecture Patrol JobStore directly.

```bash
hive patrol PROJECT --list --json
hive refactor-patrol PROJECT --list --limit 25 --json
hive refactor-patrol PROJECT --show JOB_ID --json
```

Ordinary `--list` reports lifecycle counts and at most 25 active-first,
newest-first finding summaries. It never launches Patrol. Architecture `--list`
is stable paginated history; follow `next_cursor` when `has_more` is true.
`--show` exposes one job's bounded attempts, actions, blockers, and dispositions.
Architecture findings use the v4 `fix`, `discuss`, and `dismiss` routes. `fix`
tries the confined PR path first and retains a dormant issue fallback;
`discuss` files an issue only; `dismiss` records the audited decision without
creating an action. Hive may narrow a reviewer route when evidence, confidence,
risk, or validation gates require it. Architecture `--list` and `--show` use
the `hive-refactor-patrol-jobs.v2` inspection envelope.

Report the project, current health counts, exact job or finding identity, state,
blocker reason, source PR, pending-action count, and last update. A Web or CLI
unavailable result means the durable projection could not be trusted; do not
infer health from daemon logs.
