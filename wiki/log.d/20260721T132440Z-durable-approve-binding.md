## 2026-07-21 13:24 UTC — Bind durable generic approvals to the current stage

**Action:** Fixed authenticated durable-attempt startup for daemon-dispatched
`hive approve` commands. Generic approval now validates against the resolved
task's current descriptor stage, matching `hive run`, while workflow-specific
verbs continue to validate against their registered target stage.

**Why:** The attempt context previously looked up `approve` as a workflow verb.
Because it is a generic command, that lookup raised before `Approve` could move
the task, terminalized the attempt as failed, and made every later daemon tick
replay the unchanged failed generation.

**Coverage:** Added a focused context regression for an inbox approval with an
idempotent `--from` assertion; existing workflow-verb binding coverage remains
the comparison case.
