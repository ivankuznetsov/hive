---
title: Daily activity digest
type: module
source: lib/hive/daily_digest.rb, lib/hive/daily_digest/, lib/hive/daemon/daily_digest_*.rb, schemas/hive-digest*.json
created: 2026-08-30
updated: 2026-09-06
tags: [digest, activity, projection, calendar, amendments, gaps, telegram, retention]
---

**TLDR**: `Hive::DailyDigest` is one durable host-global projection of material
activity across registered projects. It stores explicit IANA-zone intervals,
allows atomic replacement only while a day is open, freezes the closed base,
and represents late knowledge with immutable idempotent amendments. Healthy
sources remain useful when another source fails; gaps are first-class data,
not an absent record or a false empty day.

## Ownership boundary

The digest composes existing Hive authorities. Task journals, creation
receipts, publication snapshots, operational transitions, registry membership
history, daemon-observed provider/authority/capacity hold transitions, and PR
owner observations remain source evidence. The daily store does
not become a second workflow state machine, task action authority, or GitHub
cache.

The host-global projection is read through one `DailyDigest::Reader` by CLI,
Rails, Telegram rendering, and agents. Project filtering happens in that reader
and preserves the selected record identity. A reader never scans projects,
contacts GitHub or PRDigest, refreshes a record, or changes delivery state.

## Global storage

The versioned owner-private root is
`Hive::Paths.state_home/daily-digest/v1/`:

```text
daily-digest/v1/
├── intervals.json
├── records/YYYY-MM-DD/
│   ├── base.json
│   ├── frontiers.json
│   └── amendments/*.json
├── tombstones/YYYY-MM-DD.json
├── deliveries/YYYY-MM-DD.json
└── .store.lock
```

One cross-process lock serializes open replacement, close, amendment, frontier,
prune, and post-prune discard operations. JSON is canonicalized and identities
are content-derived. Atomic writes use owner-private directories/files,
same-directory rename, and directory fsync through `Hive::AtomicFile`.

`intervals.json` is rebuildable navigation metadata updated with every base or
tombstone write. CLI and Web navigation read this bounded index instead of
opening every retained base and amendment. The record schema carries a
monotonic sequence and `local_date`, persisted
zone/boundaries, lifecycle, close/materialization timestamps, projects, items,
attention, gaps, and source frontiers. Lifecycle, completeness, and content are
orthogonal. `empty` requires complete observation.

## Calendar and coverage

`daily_digest.time_zone` is an IANA identifier resolved through TZInfo. Setup
and `hive migrate` / `hive migrate --all` idempotently persist the zone,
coverage-start instant, initial membership snapshot, and first interval in one
global-config transaction. Failed or ambiguous host-zone detection leaves the
feature disabled and does not stop unrelated daemon work.

Intervals are half-open UTC ranges. Normal calendar days can therefore be 23,
24, or 25 hours. A configured zone change becomes effective at the prior
interval's immutable `ends_at`. The next interval begins at that exact instant,
uses a monotonic label, and stores `boundary_kind: zone_cutover` plus cutover
metadata. Existing boundaries are never recalculated. Sequence lookup rather
than date arithmetic assigns every instant exactly once and drives default,
previous, and next navigation.

No pre-feature history is synthesized. Coverage begins at the persisted
frontier, and migration captures membership at that boundary. Later
registration, unregistration, stale pruning, and replacement append ordered
membership-history changes under the existing global config lock. Unprovable
legacy membership becomes a scoped gap.

## Material collection

`Collector` asks each effective registered project source for normalized facts
and source health. `Materiality` owns the include/exclude matrix and stable
fingerprints. A committed source frontier includes bounded file-stat and
content fingerprints; unchanged task journals and creation receipts are not
read or hashed again during the next refresh. Changed and unavailable sources
remain isolated per project, malformed journal diagnostics are aggregated per
journal, and creation receipts have an explicit read bound. Material facts
include task creation, durable stage/state
changes, answers, changed holds, failures/recoveries, PR/check/review/merge
outcomes, completion, and archive. Polls, repeated snapshots, diagnostics, log
churn, and retries without a changed durable outcome advance bookkeeping only.

Task creation has a task-local content-derived receipt committed with capture,
because a host-global write cannot share that transaction. PR facts prefer
Hive-owned journal/publication evidence. GitHub is fail-soft and contributes a
gap only when a required PR field or freshness rule cannot be satisfied from
that evidence. V1 never invokes PRDigest.

Open-day attention may use current operational state. Closing attention is an
as-of-boundary fact reconstructed from durable entry/exit transitions. Waiting
age starts at the latest durable transition into the current blocked or
unanswered state. If state or age cannot be proved, the record closes partial
with a boundary-history gap. Waiting items use a privacy allowlist: project,
task identity, stage/state, age, and native task URL; question text, answers,
prompts, and bindings are absent from the record.

## Open, close, and amend

Only the daemon scheduler or explicit `hive digest refresh` invokes
`Coordinator`:

1. enumerate missing feature-era intervals from the coverage frontier in
   persisted sequence;
2. collect healthy facts and scoped source gaps;
3. atomically replace the current open base, or freeze an elapsed base as
   closed; and
4. commit source frontiers with the corresponding base/amendment effect.

Every retained interval, including a gapless closed record or prune tombstone,
is eligible for the cheap fingerprint refresh. This lets late evidence become
an amendment or bounded discard without requiring an existing gap. Replacing
an open base merges prior facts, attention, and frontiers for any unavailable
source rather than turning an outage into evidence deletion.

A crash before commit replays the old frontier and stable identities deduplicate
the batch. The first materialization after `ends_at` closes the base. Thereafter
`Store#write_base` accepts only a byte-identical identity and rejects
replacement.

Facts with a known event time are assigned to the persisted interval containing
that instant; otherwise `observed_at` owns assignment. A fact discovered after
its day closes becomes a separately immutable amendment with event,
observation, and amendment time. Corrections reference the corrected identity.
Gap recovery appends recovered facts and the exact resolved gap ID. Effective
completeness can improve, but the closed base bytes, lifecycle, and close time
remain unchanged.

## Degradation and recovery

Each stable gap records source, bounded scope/reason, observation/freshness,
and retry state. One unreadable project, malformed row, unavailable required PR
observation, or missing boundary transition does not suppress healthy projects.
A complete record with no content is explicit; a partial record with no known
content remains `unknown`.

Recovery retries unresolved sources through the same refresh owner. A gap
resolves only when the attempted project or task scope supplies positive fresh
membership or fingerprint evidence; disappearance of a task or project cannot
manufacture completeness. A resolved gap and recovered facts are an idempotent
amendment, visible in later CLI/Web reads. Recovery never changes Telegram
outcome or triggers a second recap.

## Retention and delivery independence

Records are retained indefinitely by default. The explicit pruner removes only
closed digest projection bytes and leaves a permanent tombstone, delivery
ledger, and all underlying evidence. Late input aimed at a tombstone is audited
and its source frontier advances atomically, preventing either reconstruction
or an endless replay loop.

Refresh/close and Telegram delivery are separate daemon children, scheduler
states, capacity identities, and positive timeouts. The close path runs whenever
the initialized daily digest is enabled, regardless of Telegram. Delivery is a
second opt-in that reads only the immediately preceding closed interval at the
configured local hour. Its intent/outcome ledger distinguishes prepared,
sending, sent, suppressed, failed, and ambiguous unknown outcomes. See
[[modules/daemon]] and [[commands/digest]].

## Output safety

Normalized records contain only bounded allowlisted fields. Rails performs HTML
escaping, terminal rendering strips control/ANSI/OSC sequences and embedded
newlines, and Telegram strips controls then escapes dynamic text for HTML parse
mode. Structured delivery logs never include the destination, token, or payload
text.

## Backlinks

- [[architecture]] · [[state-model]] · [[decisions]]
- [[commands/digest]] · [[commands/web]] · [[modules/config]] · [[modules/daemon]]
