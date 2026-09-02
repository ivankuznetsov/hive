---
title: hive circuits
type: command
source: lib/hive/commands/circuits.rb, lib/hive/provider_routing/operational_projection.rb, schemas/hive-circuits.v1.json
created: 2026-08-10
updated: 2026-09-02
tags: [command, providers, routing, circuits, sqlite, audit, operator, json]
---

**TLDR**: `hive circuits` inspects and administers provider-routing health in
the SQLite runtime control plane. It can mutate provider health only; it cannot
clear task state, request a retry, create a successor, or dispatch work.

## Inspection

```bash
hive circuits
hive circuits inspect --provider codex-primary
hive circuits inspect --provider codex-primary --model gpt-5.6-sol --json
```

Inspection combines configured accounts, attempt-derived capacity, bounded
provider-account and model circuit rows, and recent durable routing decisions.
It does not rerun selection or scan provider output. Human and JSON output omit
prompts, logs, tool output, credentials, and unsanitized provider messages.

The closed `hive-circuits.v1` envelope reports account capacity, effective and
automatic circuit state, generation, eligibility time, manual block, probe
owner, safe evidence, and the bounded decision projection. The legacy
`intent_corruptions` field remains an empty compatibility field; probe-intent
files no longer exist.

## Mutations

Inspect immediately before mutation and pass the observed generation:

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

`block` is indefinite. `unblock` removes only the manual block. `reset` clears
automatic health and stale probe ownership while preserving a manual block.
Every accepted mutation advances the target generation and writes its typed
audit row in the same transaction. A stale generation changes nothing.

The reason must be non-empty, single-line UTF-8, at most 240 bytes, and free of
control characters or credential-shaped text. Actor identity comes from the
trusted local UID. `--yes` is mandatory for mutations. SQLite corruption is
handled by runtime-control-plane recovery rather than circuit-specific file
repair commands.

## Recovery boundary

Circuit cooldown controls route eligibility only. `RecoveryCoordinator` owns
retry admission, pacing, charges, successor creation, and redispatch. Provider
administration remains intentionally absent from `hive act`.

## Errors, serialization, and exit codes

With `--json`, failures use the `hive-circuits.v1` error arm and never include
prompts, raw provider output, credentials, or unsanitized provider messages.
The shared envelope emitter's serialization policy is `warn`: if an error
envelope raises `JSON::GeneratorError`, Hive warns, emits no fallback document,
and preserves the original typed or wrapped error as the exit authority.

| Code | Meaning |
|---:|---|
| 0 | Inspection or the generation-fenced mutation completed. |
| 1 | Provider-health/runtime storage was unavailable, a generation was stale, or another ordinary Hive error occurred. |
| 64 | The action, scope, consent, reason, model, or expected generation was invalid. |
| 70 | An unexpected exception was wrapped as an internal error. |
| 78 | Provider or project configuration was invalid. |

## Tests

- `test/unit/commands/circuits_test.rb`
- `test/unit/provider_health/repository_test.rb`
- `test/unit/provider_routing/operational_projection_test.rb`
- `test/unit/runtime_control_plane/admission_transition_test.rb`

## Backlinks

- [[modules/provider_health]]
- [[modules/provider_routing]]
- [[modules/attempts]]
- [[modules/daemon]]
- [[commands/status]]
- [[cli]]
