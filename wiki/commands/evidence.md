---
title: hive evidence
type: command
source: lib/hive/commands/evidence.rb
created: 2026-08-14
updated: 2026-08-14
tags: [command, artifacts, evidence, recovery]
---

**TLDR**: `hive evidence recover` is the explicit, stale-safe operator
acknowledgement for a semantically blocked `7-artifacts` outcome-evidence
package. It never edits the blocked ledger or retries the workflow directly.

## Usage

```sh
hive evidence recover TARGET \
  --generation <sha256> \
  --recovery-digest <sha256>
```

Use `--project NAME` or `--stage 7-artifacts` to disambiguate a bare slug. The
command also accepts the ordinary explicit `PROJECT:SLUG` target. `--json`
emits one machine-readable result.

Do not invent either digest. Copy the complete command from the task's current
status diagnostic, Hivebox blocker panel, or `hive run` recovery output after
reviewing the independent reviewer reasons.

## Guards and effects

The command acquires the task lock and requires all of these observations to
still agree:

1. the task marker is the semantic outcome-evidence `ERROR` observed by the
   operator;
2. its `generation` and `recovery_digest` equal the supplied values;
3. the strict `outcome-evidence/current.json` pointer is still blocked; and
4. the immutable requirement names the current durable task generation.

On success it advances `<task>/outcome-evidence/recovery.json` by one epoch and
rewrites the marker as `ERROR reason=outcome_evidence_recovery_ready`, carrying
the exact generation, digest, and new epoch. It preserves every requirement,
attempt, retained proof, rationale, and the blocked `current.json`. Repeating
the same exact recovery is idempotent; a superseded generation/digest or
concurrent package change fails closed.

Text output names the new epoch and the preserved generation. JSON output is:

```json
{
  "status": "recovery_ready",
  "task": "example-260814-abcd",
  "blocked_generation": "<sha256>",
  "recovery_epoch": 1
}
```

Recovery deliberately stops before dispatch. Refresh
`hive status --operational --json`, obtain its fresh guarded
`workflow.retry` action/token, and invoke that normal action boundary. The new
artifacts run opens a distinct outcome-evidence generation because the recovery
epoch is part of generation identity.

## Backlinks

- [[stages/artifacts]] · [[state-model]]
- [[commands/status]] · [[commands/run]] · [[commands/web]]
