---
title: hive review-grant
type: command
source: lib/hive/commands/review_grant.rb, lib/hive/review_budget.rb, lib/hive/daemon/recovery_coordinator.rb, schemas/hive-review-grant.v1.json
created: 2026-11-02
updated: 2026-11-02
tags: [command, review, recovery, operator]
---

`hive review-grant` records an operator's decision to allow 1–3 additional
fixes for one `REVIEW_STALE reason=final_fix_unverified` review. Obtain its
grant evidence token from [[commands/status]]. The decision permits
normal daemon admission; existing recovery, provider, CI, escalation and
fix-safety gates still apply.

## Usage

```sh
hive review-grant TARGET --project PROJECT --passes N --reason TEXT --evidence-token TOKEN [--json]
```

## Options

`TARGET` is an unambiguous task ID, slug or canonical task folder.
`--project`, `--passes`, `--reason` and `--evidence-token` are required.
`--passes` is an explicit decimal integer from 1 through 3, independent of
`review.max_passes`. Fractional, partially numeric and out-of-range values
refuse. `--reason` is stripped and normalized at the wire boundary; it must
contain 1–1024 valid UTF-8 bytes, contain no control characters, and pass
`Hive::SecretScanner`. Use a non-sensitive explanation. `--json` selects the
versioned machine-readable envelope.

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
artifacts while retaining the task-root audit. Audit alone never reconstructs
active allowance. Version 1 has no release or cancel verb.

This command is non-interactive and operator-only. Hive's Claude, Codex, Pi,
Grok and OpenCode launches carry required command-denial policy and live
process provenance. The command boundary rejects managed-agent calls even
with a fresh token or overridden child environment. Available native tool
denials supplement that shared boundary. The immutable receipt and audit
capture the verified caller UID and source. This workflow boundary does not
isolate an operator from a malicious process with unrestricted access as the
same OS user.

## Examples

```sh
hive status --operational --json
hive review-grant 43397 --project hive --passes 2 \
  --reason "Finish the accepted fixes and verify the result" \
  --evidence-token TOKEN --json
```

Refresh status after progress. A further grant requires a new eligible
final-fix-unverified observation after the extension's mandatory verification.

## Output and schema

`hive review-grant --json` emits the closed `hive-review-grant.v1` schema.
Success includes `state` (`applied` or `replayed`), stable `decision_id`,
`passes`, normalized `reason`, original `caller`, `source`, `decided_at`,
`audit_path` and `remediation`. Replayed output describes the historical
decision; it does not claim a new allocation or current remaining allowance.
Read the required nullable `review_grant` field in
`hive-operational-status.v5` for current derived counts and suspended holds.
Text output identifies the decision and its result without rendering reason
text into a shell command.

## Output exceptions

`hive review-grant --json` errors use its versioned error envelope, including
`error_kind`, `exit_code`, `message` and, for dispatched refusals,
`refusal_reason` and `remediation`. Thor usage errors use the command's declared
usage envelope before dispatch. Managed sources refuse as `agent_denied`;
unverifiable process provenance refuses as `source_unverified`. Missing,
changed or corrupt evidence never allocates allowance or clears a new marker.
Shared wrapper/runtime activation failures retain their separate contracts.

## Serialization fallback

For `hive review-grant`, JSON encoding failures propagate rather than emitting
a second or partial fallback document. An `EPIPE` while emitting the error
envelope retains the underlying typed failure. Diagnostic and text rendering
escape untrusted data; reason bytes are audit data and never shell input.

## Exit codes

For `hive review-grant`, exit code `0` means applied or identically replayed.
Usage, evidence and decision-conflict refusals use `64`; task-lock contention
uses `75`; configuration errors use `78`. Managed-source refusals use `1`.
Internal failures retain the shared typed CLI exit code. Success means the
grant was recorded/applied, not that the review succeeded.

## Backlinks

- [[cli]] · [[stages/review]] · [[modules/daemon]] · [[commands/status]]
