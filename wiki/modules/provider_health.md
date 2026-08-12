---
title: Hive::ProviderHealth
type: module
source: lib/hive/provider_health.rb, lib/hive/provider_health/*.rb, schemas/hive-provider-health*.json
created: 2026-08-10
updated: 2026-08-11
tags: [provider-accounts, models, circuits, journals, probes, audit]
---

**TLDR**: `Hive::ProviderHealth` is Hive's owner-private, host-global
eligibility store for explicitly routed provider accounts and exact models. It
accepts only typed evidence from reviewed structured adapter channels or an
explicitly separated provider diagnostic,
serializes scoped generation-CAS mutations under one health lock, and rebuilds
`current.json` from authoritative per-scope journals only on mutation paths.
Read-only inspection samples journals without repair or projection writes. It never schedules a
retry, charges a budget, creates a successor, dispatches work, or owns a task
marker.

## Scope and composition

Each provider-account scope and each exact provider/model scope has its own
journal. Route eligibility composes both enclosing scopes at read time:

- an account block or open circuit excludes every model on that account;
- an exact-model block or open circuit excludes only that route;
- reset or unblock changes only its target and does not erase the other scope;
- a manual block is orthogonal to automatic open/closed health;
- half-open is a read-time view once `eligible_at` is reached and does not
  itself write an event or advance generation.

The closed provider-account classes are authentication,
billing/configuration, exhausted credits, account/session quota,
provider-wide rate limit, and provider outage. Exact-model classes are
unavailable, disabled, deprecated, model quota, model rate, and model capacity.
Class and scope must be compatible.

## Sanitized evidence

`Evidence` can be constructed only with an explicit scope, one allowlisted
provenance tag, the admitted typed route, a bounded reset hint, an attempt ID,
and an integrity-bearing protected output reference. Its persisted form is
smaller: class, explicit scope, provenance, configured route ID, bounded reset
hint, safe fingerprint, and protected reference. Adapter identity, launch
binding, attempt fence, raw diagnostic text, prompt, stdout/stderr, final
message, tool output, tokens, and credentials are not persisted as evidence.

The fingerprint is SHA-256 over canonical safe fields only. Changing a raw
message or artifact path cannot create a new shared-health identity. Untrusted,
ambiguous, wrongly scoped, stale-generation, late, or fenced evidence cannot
advance a circuit generation.

Integrity-reference shape validation comes from the lower-level
`Hive::OutputReference` custody primitive. Provider Health does not import or
depend on the Attempts component merely to validate that metadata.

The current adapter transport allowlist is deliberately narrow: a real Claude
subscription `rate_limit_event` with rejected `five_hour` or `seven_day`
status can produce provider-account `account_quota` evidence when it arrives
from the admitted launch binding. Current Codex, Grok, and Pi transport shapes
cannot produce shared-health evidence. Their historical provenance identifiers
remain readable for durable-record compatibility, but the runtime normalizer
does not emit them.

## Storage and replay

State lives below `provider-health/v1` with owner-only directory and file
modes:

```text
provider-health/v1/
├── mutation.lock
├── scopes/provider-account/<scope-digest>/{journal.jsonl,current.json}
├── scopes/model/<scope-digest>/{journal.jsonl,current.json}
├── history/<scope-kind>/<scope-digest>/*.jsonl
├── idempotency/<scope-kind>/<scope-digest>/shards/<00..3f>.json
├── intents/<intent-digest>.json
└── quarantine/<scope-kind>/<scope-digest>/...
```

Every authoritative event embeds the unhashed scope, journal epoch, sequence,
idempotency key, expected/previous/resulting generation, and a recursively
closed sanitized payload. Operator block, unblock, and reset events embed the
audit receipt in the same journal write; audit is not a best-effort second
append. `current.json` is disposable and repaired from replay by mutation paths.

Before an append would exceed 4,096 active events or 2 MiB, the store archives
the verified active journal, records its idempotency receipts across at most 64
bounded shards, and atomically replaces it with a non-mutating `snapshot`
event. Each shard is written at most once per compaction; readers retain the
legacy point-receipt fallback for previously compacted state.
The snapshot preserves circuit state, generation, epoch, manual block,
evidence, and live probe ownership; the pending event is then appended at the
new active sequence. Archived idempotency receipts keep old evidence replay a
no-op after restart, while the active replay cost remains bounded.

An unterminated final record after a verified record is replayed transparently
without changing the journal: a complete JSON record receives a virtual
newline, while a malformed suffix after the final newline is ignored.
An existing empty journal or malformed first record has no verified genesis
and therefore fails closed without being rewritten. Inspection and route
evaluation remain read-only. The next mutation after a verified torn tail uses
the exact original bytes as its compare-and-swap source and replaces the tail
while appending the new event in one atomic journal write. An interior parse
failure, schema-invalid event, sequence or generation gap, duplicate event
identity, probe outcome without an owned probe, mismatched probe binding, or
other impossible transition returns the scoped
`health_state_unavailable` blocker without parser content. Inspection exposes
a bounded repair token containing scope, journal epoch, corruption
fingerprint, and last verified generation.

A corrupt reset must match that fresh token. It copies the exact corrupt bytes
to owner-private quarantine, starts a new scoped epoch above the last verified
generation, preserves the last verified manual block, clears automatic health
and stale probe state, and journals one audited reset with the quarantine
reference. Old probe results are fenced by epoch and generation.

## Probe intent and ownership boundary

When an ordinary attempt needs one or both half-open scopes, callers create one
typed multi-scope `ProbeIntent`. The store validates the full observed
generation vector, persists the intent, yields immutable probe bindings while
the caller durably writes the launching attempt, journals each claim, and then
removes the intent. The intended lock order is admission lock, task-generation
lock, then health lock.

An unresolved intent makes its scopes unavailable to another selector.
Restart reconciliation consults the durable attempt reader: it finalizes
missing claims for the exact live attempt, rolls back an intent with no
admitted attempt, or conservatively reopens claims for terminal/lost/fenced
ownership. There is no probe timer or second lease store.

A malformed intent cannot be scoped reliably, so route evaluation remains
globally fail-closed. `Store#inspect_probe_intents` exposes a bounded token for
each exact corrupt artifact. The approved `hive circuits reset-intent` path
revalidates its filename and digest, refuses a valid or stale artifact,
quarantines the bytes with an audit receipt, and removes only that exact source
file. This gives operator recovery without silently discarding possible
in-flight ownership.

Operator block, unblock, and reset first reconcile an unresolved intent, then
repeat the operator's generation compare-and-swap against the replayed scope.
If reconciliation accepted a live probe claim, the operator action is rejected
as stale and requires fresh inspection; the claim and action can never both be
accepted from one observed generation. An already advanced live-intent scope
is treated as a fenced rollback rather than making the whole health store
unavailable.

`Store#with_route_admission` is the admission-side CAS seam. It replays and
checks every enclosing scope against the router's immutable observation while
the Attempts admission and generation locks are already held. Closed scopes,
half-open requirements, manual blocks, existing probes, epochs, generations,
and unresolved intents are all revalidated. The yielded callback persists the
attempt while the health lock remains innermost; multi-scope claims then use
the existing intent protocol. A stale observation performs no attempt or
health mutation and asks the dispatcher to select again.

Preselection uses `Store#evaluate_routes` for the complete ordered pool. One
host-global lock hold scans probe intents once and replays each unique account
or model journal once, then returns route evaluations in input order. The
single-route API delegates to that batch path, so large pools do not multiply
intent scans or replay shared account journals.

## Terminal attempt observation

`AttemptObserver` consumes only immutable final explicit-attempt records. It
reconstructs the exact route, ownership fence, circuit observation vector, and
probe bindings from the record rather than mutable configuration. A terminal
success closes only generation-matched probes; failure, cancellation, or
proven loss reopens each owned probe conservatively. A following safe failure
signal opens only its explicit provider-account or exact-model scope.

The idempotency key binds attempt ID, immutable terminal receipt version,
terminal lease version, route, and safe fingerprint. Duplicate replay is a
no-op. Operator generation changes, stale epochs, late receipts, and fenced
attempts cannot close, reopen, or release another attempt's probe. A valid
task-local or absent signal still receives the named finalization
acknowledgement without changing a generation, preventing recovery deadlock.

## Operator controls

`hive circuits` is the only public administration surface for provider health.
Provider-account and exact-model `block`, `unblock`, and `reset`, plus global
`reset-intent`, require
explicit `--yes`, a bounded validated reason, trusted local actor identity, and
either the fresh healthy generation or the complete scoped corruption token.
Probe-intent reset instead requires its exact inspection file token and digest.
Credential-shaped text, including hyphenated `sk-proj-...` forms, is rejected
before an audit event can be written.
Circuit mutation and its typed audit receipt are one journal operation;
probe-intent repair stores its quarantine artifact and audit receipt before
removing the corrupt source.

Unblock removes the manual block and any probe ownership fenced by the operator
generation change. Ordinary reset clears automatic health
and stale probe state while preserving the manual block. Corrupt reset
quarantines exact bytes into a new epoch and likewise preserves the last
verified block. All accepted actions advance the target generation; stale
inputs do nothing. None of these actions touches attempts, markers, recovery
receipts, retry counts, deadlines, successors, or dispatch. See
[[commands/circuits]].

No-hint evidence uses the frozen account policy's failure-class cooldown when
terminal finalization opens the circuit; missing or unavailable frozen policy
falls back to the conservative store default.
