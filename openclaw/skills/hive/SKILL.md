---
name: hive
description: "Operate Hive task pipelines and pre-release QA through its native CLI. Use when an agent needs to answer current Hive or Hive-bench status, identify the exact active task and blocker owner, follow work through bounded transitions, inspect candidate QA evidence, advance a fresh routine recommendation, diagnose recovery state, initialize or configure Hive, or explain what requires operator action across registered projects."
version: "0.1.3"
user-invocable: true
metadata:
  openclaw:
    homepage: "https://github.com/ivankuznetsov/hive"
    always: true
    install:
      - id: homebrew
        kind: brew
        formula: ivankuznetsov/hive/hive
        bins: [hive]
---
<!-- hive-managed: canonical-skill-projection/v1
platform: openclaw
invocation: /hive
skill-version: 0.1.3
canonical-digest: c8aacce6c5e2af2a84c51c65d0b756613a14c686c839321f8a79b9a38a172a7a
hive-version: 0.6.9
-->

Invoke this projection as `/hive`.

# Hive Operations

Use Hive as the control plane. Do not replace its status, watch, scheduler, or recovery machinery with shell polling, process discovery, or an agent-authored sidecar.

## Operating loop

1. Request a fresh machine snapshot with `hive status --operational --json`.
2. Check `ok`, `completeness`, task-graph freshness, and scheduler freshness before making a confident claim.
3. Report counts, the exact `project:slug`, state, blocker owner, reason, stage/marker, and provider or scheduler evidence when present.
4. Use `hive watch ... --json-lines` when the user wants ongoing status. Declare a target and terminal bound; do not write a polling loop.
5. Execute only a fresh action descriptor whose risk is routine, confirmation is not required, and opaque observation token came from that same task row. Use `hive act`; never execute status text or arbitrary argv.
6. Request another operational snapshot after any action. Never assume that a successful command proves the later pipeline state.

## Operational vocabulary

- `running`: a verified live worker owns the task.
- `waiting_on_you`: a genuine operator decision or answer is required.
- `needs_repair`: Hive or an operator must repair a failed or stale condition.
- `waiting_on_provider_or_scheduler`: current evidence attributes the wait to quota, capacity, cooldown, dependency, or another scheduler gate.
- `completion_ready`: work reached a completion boundary but is not necessarily archived.
- `idle`: the task is ready for dispatch and has no current worker.
- `unknown`: evidence is incomplete or contradictory; say what is missing.

Do not reinterpret `idle` as “nothing is happening” without checking ownership and scheduler evidence. Do not attribute a provider wait unless the current snapshot names the provider or a current scheduler disposition proves it.

## Authority boundary

Proceed with read-only inspection and bounded watching. Proceed with an emitted routine action only when all freshness and action-policy checks above pass. Follow direct user requests for normal non-destructive workflow work through Hive’s documented verbs.

Ask before destructive or administrative changes, marker clearing, force/bypass options, stopping automation, replacing installed configuration, changing destinations, publishing externally, deploying, tagging, releasing, or changing release-version metadata. Preserve task folders, worktrees, attempts, queues, locks, and recovery evidence while diagnosing.

## Load the relevant reference

- Read [status-and-watch.md](references/status-and-watch.md) for status interpretation, reporting, compatibility, and native watch semantics.
- Read [workflow-actions.md](references/workflow-actions.md) for task creation, direct workflow verbs, daemon ownership, closed actions, and completion checks.
- Read [recovery.md](references/recovery.md) for diagnosis, coordinator ownership, provider holds, stale workers, migration, and guarded recovery.
- Read [setup-and-platforms.md](references/setup-and-platforms.md) for installation, initialization, agent-skill setup, and platform invocation conventions.
- Read [release-candidate-qa.md](references/release-candidate-qa.md) for semantic E2E discovery, local candidate evidence, bounded hosted collection, retry semantics, and the explicit hosted-dispatch boundary.
- Read [safety.md](references/safety.md) before any admin, force, credential, external-publication, deployment, or release-sensitive operation.
