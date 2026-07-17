---
title: hive retry
type: command
source: lib/hive/commands/retry.rb
created: 2026-07-17
updated: 2026-07-17
tags: [command, retry, daemon, recovery, audit]
---

**TLDR**: `hive retry` is the only operator surface that changes durable task
retry state. Every action requires the task generation the operator inspected;
state-changing actions also require an actor and reason.

## Usage

```text
hive retry manual  <target> --generation N [--project NAME] [--json]
hive retry repair  <target> --generation N --actor WHO --reason WHY [--project NAME] [--json]
hive retry reset   <target> --generation N --actor WHO --reason WHY [--project NAME] [--json]
hive retry abandon <target> --generation N --actor WHO --reason WHY [--project NAME] [--json]
hive retry rearm   <target> --generation N --actor WHO --reason WHY [--project NAME] [--json]
```

`reset` aliases `repair`; `re-arm` aliases `rearm`. A target may be a task slug
or folder accepted by `TaskResolver`.

## Actions

| Action | Durable effect |
|--------|----------------|
| `manual` | Records/wakes operator intent. It may evaluate a due or ready record but never bypasses an unexpired `retry_after` and never resets the count. |
| `repair` / `reset` | Audits the repaired condition, clears the ladder baseline, and makes the current generation eligible for normal capacity-gated dispatch. |
| `abandon` | Audits an operator-only transition to `abandoned`. Automated callers cannot abandon and no maximum count auto-abandons. |
| `rearm` / `re-arm` | Audits reversal of abandonment, resets the ladder, and returns the current generation to ordinary dispatch eligibility. Immutable prior history remains in the task journal. |

The expected generation is a compare-and-set fence. A stale generation is
rejected without replacing the current projection. Commits, dirty worktrees,
artifacts, checkpoints, error class, and attempt id are not reset criteria.

## Output

Human output summarizes the accepted action, projected state, count, and
deadline. `--json` emits `hive-retry-action` version 1 with `action`, `project`,
`task`, and the exact replacement `retry` projection. Consumers should obtain
the current generation and state from `hive status --json`; they must not derive
them from marker attrs.

## Backlinks

- [[commands/status]]
- [[modules/daemon]]
- [[modules/events]]
- [[state-model]]
