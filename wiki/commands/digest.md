---
title: hive digest
type: command
source: lib/hive/commands/digest*.rb, lib/hive/daily_digest/, schemas/hive-digest*.json
created: 2026-08-30
updated: 2026-09-06
tags: [command, digest, activity, history, json, telegram, retention]
---

**TLDR**: `hive digest` reads Hive's persisted host-global daily activity
projection. The default text view and the `--json`, date, and project views are
pure reads: they never collect source data, advance a frontier, open a browser,
or send Telegram. The explicit `refresh`, `send`, and `prune` subcommands own
those separate effects.

## Synopsis

```bash
hive digest [--date YYYY-MM-DD] [--project NAME] [--json] [--open-web]
hive digest refresh [--date YYYY-MM-DD] [--json]
hive digest send --date YYYY-MM-DD [--retry] [--json]
hive digest prune --before YYYY-MM-DD (--dry-run | --yes) [--json]
```

`--json` and `--open-web` are mutually exclusive. A project filter is a view
over the selected global record: it keeps the same record identity and
boundaries and retains global gaps. It never creates or rewrites a project-only
digest.

## Selecting a day

With no `--date`, Hive selects the persisted half-open interval containing the
current UTC instant. It does not derive a filename from the host's current
calendar date. This matters after an eastward, westward, or International Date
Line zone cutover, where the monotonic stored label may temporarily differ from
the new zone's wall-clock date.

JSON supplies `previous_date` and `next_date`. Callers asking for "yesterday"
must follow `previous_date`; subtracting one from `local_date` is not a valid
navigation rule. An explicit ISO date remains a stable record identifier.

## Pure reads

The text view leads with local date, persisted IANA zone, lifecycle,
completeness, content, and materialization freshness. It then shows attention,
source gaps, project activity, late amendments, and the canonical Web URL.
Every dynamic terminal field is control- and ANSI-sanitized. CLI, Web, and
Telegram share deterministic item ordering; CLI and Web also share project
group order and bounded stage/PR/check/review outcome labels.

The `hive-digest` v1 JSON envelope is the stable agent contract. Its main
fields are:

- record and interval identity, sequence, persisted zone, UTC boundaries, and
  optional cutover metadata;
- `reader_status`, lifecycle, effective completeness, content, freshness, and
  coverage information;
- persisted projects, filtered activity, boundary attention, gaps, and
  append-only amendments;
- native task/PR URLs and the canonical `web_url`; unresolved tasks from a
  removed or identity-replaced registration are marked historical and lose
  their actionable task URL; and
- persisted-sequence `previous_date` / `next_date` navigation.

The ordinary reader has no coordinator, delivery service, Telegram transport,
or cursor dependency. `--open-web` is the only read option that invokes the
browser opener, exactly once and only after option validation.

## Reader states

The three axes are independent:

- lifecycle is `open`, `closed`, or the tombstone outcome `pruned`;
- completeness is `complete` or `partial`; and
- content is `empty`, `non_empty`, or `unknown`.

`missing` is a reader outcome, not a stored lifecycle. A date before
`coverage_started_at` is deliberately not backfilled. A complete observation
with no activity or boundary attention is explicitly `empty`; a partial record
with no known items is `unknown`, never a successful empty claim. An open
record older than `freshness_budget_sec` is returned as stale with a virtual
materializer gap, without mutating its bytes.

A project filter recomputes completeness and content from the filtered items,
attention, and applicable global/project gaps while retaining the global
record identity. It cannot report `partial` with no visible gap or `non_empty`
with no visible content.

## Explicit refresh

`hive digest refresh` invokes the coordinator. It catches up feature-era
intervals in sequence from the configured coverage frontier, repairs earlier
holes even if a later record already exists, closes elapsed records, refreshes
retained intervals for late observations, and retries unresolved source gaps.
`--date` selects a feature-era interval;
future and pre-coverage dates return typed errors.

Refresh is also the operator remediation for a stale current projection or a
recoverable feature-era missing day. It remains explicit: CLI, JSON, and Web
reads never invoke it implicitly.

## Explicit Telegram delivery

`hive digest send --date DATE` accepts only a closed, non-pruned record. It uses
the same durable delivery ledger as the opt-in daemon scheduler and sends only
to `Config.telegram_chat_id!`, the first configured private allowlisted chat.
Additional broadcast/allowlisted chats receive no recap.

A complete empty day records `suppressed_empty` without requiring a token or
sending a message. `sent` is deduplicated. A process interruption after the
external effect can leave `sending`; the next delivery preparation checks the
recorded sender process identity and promotes a dead owner's intent to
`unknown`, which is never retried automatically. A still-live owner produces a
typed `delivery_in_flight` outcome. After checking Telegram, the operator may use
`--retry` to record a new explicit attempt. Later record amendments do not
implicitly re-send a recap.

Delivery errors name the exact refresh remediation for an open record and
expose the automatic retry limit in JSON. Digest reader and delivery failure
classes use stable non-generic exit codes so shell callers can distinguish
invalid input, unavailable history/state, and configuration failures.

## Explicit projection pruning

Pruning is deliberately two-step:

```bash
hive digest prune --before 2026-08-01 --dry-run
hive digest prune --before 2026-08-01 --yes
```

Only closed records strictly before the cutoff are eligible. The confirmed
operation removes the base, amendments, and projection frontier for each day,
but retains its tombstone/audit receipt and delivery receipts. It does not
delete task journals, task folders, attempts, publication evidence, or any
other source authority. A later fact, correction, or recovered gap targeting a
pruned day becomes one idempotent bounded discard entry on the tombstone while
the matching source frontier advances; Hive never silently reconstructs the
removed projection.

## Related pages

- [[modules/daily-digest]] — storage, calendar, collection, and lifecycle.
- [[modules/daemon]] — independent refresh/close and delivery scheduling.
- [[commands/web]] — authenticated selected-day Web surface.
- [[modules/config]] — initialization and opt-in configuration.
