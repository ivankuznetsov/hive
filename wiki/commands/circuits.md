---
title: hive circuits
type: command
source: lib/hive/commands/circuits.rb, lib/hive/provider_routing/operational_projection.rb, schemas/hive-circuits.v1.json
created: 2026-08-10
updated: 2026-08-10
tags: [command, providers, routing, circuits, audit, operator, json]
---

**TLDR**: `hive circuits` is the explicit provider-routing inspection and
administration surface. Inspection joins the bounded durable decision index,
attempt-derived account capacity, and provider-account/exact-model health
journals without rerunning route selection. `block`, `unblock`, and `reset`
require a fresh generation, a validated reason, and `--yes`; corrupt-state
reset instead requires the complete fresh repair token. The command can mutate
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
health nor attempt storage.

Human output is concise. The closed `hive-circuits.v1` JSON contract includes:

- current account capacity as observed/max, derived from durable live attempts;
- provider-account and exact-model effective/automatic state, generation,
  journal epoch, eligibility time, manual block, probe owner, safe evidence,
  protected artifact reference, and corruption repair token;
- the latest bounded durable route decisions with project, task generation,
  task subject, optional admitted attempt ID, policy digest and requirements,
  selected route or no-selection reason, ordered candidates/exclusions,
  circuit observations, capacity, and next-action owner.

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

## Corrupt-state reset

An unavailable scope exposes a token containing `journal_epoch`,
`corruption_fingerprint`, and `last_verified_generation`. Supply all three and
omit `--expected-generation`:

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
