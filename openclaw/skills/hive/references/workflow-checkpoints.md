# Workflow checkpoints

Checkpoints are durable human stages, not comments in an agent instruction.
Add one only when the request names a decision or the next action would be
irreversible, externally visible, privileged, or otherwise high consequence.

Declare a small closed set of named outcomes. Each outcome either completes
with a verified artifact or returns to an existing stage. Hive records the
decision with its stage visit identity, note, artifact, and timestamp.

Operate a waiting checkpoint with:

```bash
hive decide TARGET OUTCOME --from STAGE --decision-id DECISION_ID --note "REASON" --json
```

Read `DECISION_ID` from the waiting stage's `hive run --json` response. The
stage and visit observations make retries safe. Repeating the same decision is
a no-op; a stale or conflicting decision is rejected. Do not bypass a
checkpoint with marker edits, a forced move, or an inferred external action.
