---
title: hive review-grant
type: command
source: lib/hive/commands/review_grant.rb, lib/hive/review_budget.rb, lib/hive/daemon/recovery_coordinator.rb, lib/hive/review_base_merge_adoption.rb, schemas/hive-review-grant.v1.json
created: 2026-11-02
updated: 2026-11-24
tags: [command, review, recovery, operator]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-review-grant) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

`hive review-grant` records an operator's decision to allow 1–3 additional
fixes for one `REVIEW_STALE reason=final_fix_unverified` review. Obtain its
grant evidence token from [[commands/status]]. The decision permits
normal daemon admission; existing recovery, provider, CI, escalation and
fix-safety gates still apply.

## Behavior

Only an evidenced final-fix-unverified park qualifies. Other stale reasons
and ordinary pass-cap exhaustion retain their existing recovery routes.
Old tasks qualify without a scheduler recovery observation when their
identity, task journal, worktree, retained reviewer/triage artifacts and
preceding HEAD-bound completion receipt prove the exhaustion. A marker's
counters alone are insufficient. Accepted counts use the runner's predicate
for both reviewer files and legacy escalations: checked `SUPPRESSED`,
`RESOLVED/NO-FIX`, `RESOLVED` and `NO-FIX` lines do not count.
Missing evidence produces a specific repair or refresh instruction; there is
no incomplete-evidence adoption command.

The coordinator re-resolves the task under its lock, validates the operator
source and exact evidence, creates an immutable private
`reviews/review-grant-<observation-digest>.json` receipt, and fsyncs its
append-only `review-budget/audit.jsonl` entry before clearing the exact stale
marker. Interrupted application reconciles the intact receipt and audit.
Neither replay nor reconciliation may clear a changed marker.

The evidence token is specific to grants. It differs from the scheduler
observation passed to `hive act --observation`; neither token authenticates an
operator. The same observation plus identical normalized amount and reason
returns the stored decision, including its original timestamp and attribution,
without allocating again. A different amount or reason conflicts. Replaying
an expired or archived decision returns history without reactivating it.
That replay also remains inert after the reset review becomes eligible or
receives its own grant; its marker and allowance belong to the new decision.

The first resumed fix uses the accepted findings already present at the
exhausted pass. Operators may fill originally empty answer slots during the
normal escalation pause; immutable framing and answer hashes reject changed
questions or rewritten original answers. Verification, triage, CI repairs and escalation-only pauses
spend no granted fix slot. Each successful granted fix has a sealed immutable
`kind=fixed` completion receipt tied to its decision and logical slot;
if an operator then fills another previously empty answer before the next
review starts, only that new answer uses the next available logical slot.
The reviewer pass number may stay the same; the original completion remains
sealed. New completions retain answer hashes to distinguish already applied
decisions from later answers without depending on file timestamps.
Guardrail approval cannot make an actual fix free. Spending alone does not
admit the diff: the pass also requires a `kind=fixed` success sentinel bound
to the completion HEAD and, for later slots, its decision and slot identity.
A restart before that sentinel rechecks the recorded
input/output HEAD diff before CI or reviewers advance, preserving an existing
guardrail approval pause. Changed HEAD or dirty worktree edits refuse recovery.
The final fix always owes another review and normal exact-head CI and
completion gates. Findings after
the last slot create a fresh eligible exhaustion. There is no cumulative
grant policy cap and no global configuration change.

Ordinary commits and daemon restarts retain the original scope. Non-final
parks suspend unused allowance and retain incomplete slots; existing recovery
rules alone decide whether the task can resume. Changed or ambiguous evidence
refuses reuse. Completion, a new review/reset or an integer task-input
generation change expires the scope. Reset archives receipts with pass
artifacts while retaining the task-root audit. Adopting a PR branch that was
fast-forwarded outside Hive is such a reset: the audit records
`expiry_reason=remote_fast_forward_adopted` and the next review starts a new
generation on the adopted head (see [[publication-recovery]]). Adopting the
operator's base merge after `REVIEW_CI_STALE reason=base_conflict` is the
other such reset. It applies only when HEAD is one merge commit of the blocked
head with a commit already on `origin/<base>`, and the grant validates at the
blocked head. The audit records `expiry_reason=base_merge_adopted`, and one
fresh review of the merged head follows, with no grant allowance. Any other
head change keeps the `review_grant_evidence_changed` refusal. Audit alone never reconstructs
active allowance. Version 1 has no release or cancel verb.

This command is non-interactive and operator-only. Hive's Claude, Codex, Pi,
Grok and OpenCode launches carry required command-denial policy and live
process provenance. The command boundary rejects managed-agent calls even
with a fresh token or overridden child environment. Available native tool
denials supplement that shared boundary. The immutable receipt and audit
capture the verified caller UID and source. This workflow boundary does not
isolate an operator from a malicious process with unrestricted access as the
same OS user.

## Backlinks

- [[cli]] · [[stages/review]] · [[modules/daemon]] · [[commands/status]]
