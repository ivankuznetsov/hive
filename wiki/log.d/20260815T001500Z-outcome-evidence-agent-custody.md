---
title: Keep outcome-evidence custody scoped to the provider call
date: 2026-08-15
---

Outcome-evidence role runners now pass an `ArtifactFirewall::AgentCustody`
boundary through the shared agent launcher instead of snapshotting protected
task files around the entire controller call. Session start/finish activity,
usage capture, projection-checkpoint refresh, and context receipts therefore
remain trusted controller bookkeeping outside the untrusted provider interval.

The role still fails closed when custody is skipped, when an agent changes a
protected anchor, or when restoration cannot establish a safe post-spawn
state. This fixes the real CLI happy path after current-main activity
checkpoint refreshes made both `task-journal.jsonl` and
`task-projection.json` change during an evidence role without any agent
tampering.
