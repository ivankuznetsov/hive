---
title: hive circuits
type: command
source: lib/hive/commands/circuits.rb, lib/hive/provider_routing/operational_projection.rb, schemas/hive-circuits.v1.json
created: 2026-08-10
updated: 2026-08-11
tags: [command, providers, routing, circuits, audit, operator, json]
---

**TLDR**: `hive circuits` is the explicit provider-routing inspection and
administration surface. Inspection joins the bounded durable decision index,
attempt-derived account capacity, provider-account/exact-model health
journals, and global probe-intent integrity without rerunning route selection.
`block`, `unblock`, `reset`, and `reset-intent` require a fresh token where
applicable, a validated reason, and `--yes`. The command can mutate
provider health only. It cannot clear a task marker, request or charge a retry,
create a successor, dispatch work, or invoke a stage verb.

## Inspection

```bash
hive circuits
hive circuits inspect --provider codex-primary
hive circuits inspect --provider codex-primary --model gpt-5.6-sol --json
```

With no provider filter, inspection lists every globally configured provider
account and configured model in normalized order. `--model` requires
`--provider` and always names one exact configured route. With no configured
accounts, the result is `not_configured`; the command opens neither provider
account circuit journals nor attempt storage, but it still inspects the global
probe-intent directory so corrupt ownership can be repaired.

Human output is concise. The closed `hive-circuits.v1` JSON contract includes:

- current account capacity as observed/max, derived from durable live attempts;
- provider-account and exact-model effective/automatic state, generation,
  journal epoch, eligibility time, manual block, probe owner, safe evidence,
  protected artifact reference, and corruption repair token;
- the latest bounded durable route decisions with project, task generation,
  task subject, optional admitted attempt ID, policy digest and requirements,
  selected route or no-selection reason, ordered candidates/exclusions,
  circuit observations, capacity, and next-action owner.
- bounded global probe-intent corruption rows with an opaque file token,
  digest, and protected artifact reference.

Decision enumeration is inspection-only and hard-capped. Admission and replay
remain point-addressed. The projection uses persisted typed values; it never
reruns the router or rescans raw provider output. Raw prompts, stdout/stderr,
final messages, tool output, tokens, credentials, and unsanitized provider
messages are absent from both renderings.

## Healthy-state mutations

Inspect the target immediately before mutating it, then supply that exact
generation:

```bash
hive circuits block \
  --provider codex-primary \
  --expected-generation 4 \
  --reason "planned account maintenance" \
  --yes

hive circuits unblock \
  --provider codex-primary \
  --model gpt-5.6-sol \
  --expected-generation 5 \
  --reason "model maintenance complete" \
  --yes

hive circuits reset \
  --provider codex-primary \
  --expected-generation 6 \
  --reason "clear verified automatic health" \
  --yes
```

`block` is indefinite. `unblock` removes only the manual block and preserves
automatic health. An ordinary `reset` clears automatic health and stale probe
state but preserves a manual block. Every accepted mutation advances the one
target generation and journals its actor, time, validated reason, target,
previous/new typed state, event ID, and generation atomically.

The reason must be non-empty, single-line UTF-8, at most 240 bytes, and free of
control characters or credential-like text. Actor identity is derived from the
trusted local UID; there is no public actor option. Generation values must be
non-negative integers. A stale generation rejects without mutation or a
successful audit receipt.

When `--json` is requested, argv-shape failures rejected by the CLI wrapper
(including unknown options and excess positional arguments) use the same
closed `hive-circuits.v1` error envelope as errors raised after command
dispatch. Automation can therefore parse every JSON-mode usage failure without
falling back to stderr prose.

## Corrupt-state reset

An unavailable scope exposes a token containing `journal_epoch`,
`corruption_fingerprint`, and `last_verified_generation`. Supply all three and
omit `--expected-generation`:

The human inspection line prints these as `repair_epoch`,
`repair_fingerprint`, and `repair_last_verified_generation`, so the complete
reset command can be constructed without switching to JSON.

```bash
hive circuits reset \
  --provider codex-primary \
  --journal-epoch 0 \
  --corruption-fingerprint SHA256_FROM_INSPECTION \
  --last-verified-generation 4 \
  --reason "verified scoped journal repair" \
  --yes
```

The store verifies the fresh token, quarantines the exact corrupt scoped
artifact owner-privately, creates a new scoped epoch above the last verified
generation, preserves the last verified manual block, clears automatic
health/stale probe state, and emits one audit receipt with the quarantine
reference. Reuse or mismatch of any token field fails closed. Unrelated scopes
and task/recovery state are unchanged.

## Corrupt probe-intent reset

A corrupt global probe-intent cannot be attributed to one route safely, so
explicit routing fails closed until the artifact is repaired. Inspection
returns `intent_corruptions` and marks the projection degraded. Supply one
row's exact file token and fingerprint:

```bash
hive circuits reset-intent \
  --intent-file FILE_FROM_INSPECTION \
  --corruption-fingerprint SHA256_FROM_INSPECTION \
  --reason "verified corrupt probe-intent quarantine" \
  --yes
```

The store re-reads and re-hashes the exact owner-private file while holding the
health lock, refuses a stale token or a now-valid intent, copies the bytes and
an audit receipt into quarantine, and only then removes the source. No circuit
generation, attempt, retry, or task state is changed. A valid unresolved intent
cannot be removed through this action.

## Approval and recovery boundary

These are direct approval-requiring administrative commands. Provider circuit
actions and forced probes are intentionally absent from `hive act`; forced
probe is not implemented. A live probe attempt is not cancelled by an operator
mutation. The generation advance fences its later health result, and ordinary
attempt reconciliation retires the stale binding.

Health cooldown only controls route eligibility. It does not create a retry
deadline. The scheduler owns neutral capacity observations, and
`RecoveryCoordinator` remains the only owner of retry admission, backoff,
charges, successor creation, and redispatch.

## Tests

- `test/unit/commands/circuits_test.rb`
- `test/unit/provider_routing/operational_projection_test.rb`
- `test/unit/attempts/decision_index_test.rb`
- `test/unit/component_boundaries_test.rb`
- `test/unit/recovery_authority_test.rb`

## Backlinks

- [[modules/provider_health]]
- [[modules/provider_routing]]
- [[modules/attempts]]
- [[modules/daemon]]
- [[commands/status]]
- [[cli]]
