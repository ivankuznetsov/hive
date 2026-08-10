# 2026-07-26 — Isolate WorkLedger mechanics without publishing a disk format

**Why:** Hive's task journal, projection, and workflow descriptor code mixed
reusable durability/topology mechanics with Hive-specific conditions, attempts,
task paths, overlays, transitions, and migration policy.

**Change:** Added the clean `Hive::WorkLedger` facade for ordered descriptor
topology validation, locked/fsynced JSONL append with complete writes,
idempotency conflict detection and rollback, and deterministic replay with
caller-injected record validation. Typed receipts bind descriptor structure or
the exact cursor, final record identity, and SHA-256; a narrow public
`JournalHandle` exposes append and idempotent append. `Hive::Workflow`,
`Hive::TaskJournal`, and `Hive::TaskProjection` now adapt those mechanisms while
retaining their existing public errors, event envelopes, attempt validation,
projection semantics, snapshot formats, and historical replay behavior.

**Boundary:** WorkLedger owns only `lib/hive/work_ledger.rb` and
`lib/hive/work_ledger/`. It defines no public disk schema.
`TaskProjection::Store` remains Hive-owned composition and may open the
canonical Attempts store, so the former Attempts/WorkLedger catalog cycle and
U8 migration exception are removed honestly. Conditions, task paths,
transitions, overlays, Git, operational status, and all migrations remain
above the facade.

**Enforcement:** The component catalog marks WorkLedger `boundary-ready`,
forbids production construction or direct requires of its internal validator,
journal, and replay classes, and fresh-process loads the facade without
Attempts, conditions, workflows, commands, stages, or web code. Focused tests
pin malformed topology, append/fsync/idempotency/rollback, invalid and duplicate
replay, Hive adapter compatibility, project overlay isolation, and historical
projection fixtures.

**Scope:** Hive remains the first and primary consumer. No gem, public journal
or projection format, package version, tag, release, deployment, or repository
split was introduced.

**Review hardening:** Receipt record trees are now detached, deeply frozen JSON
snapshots; replay binds its cursor and hash to a private copy of the supplied
bytes; and idempotent lookup checks every historical key match so a later
conflicting duplicate cannot be hidden by an earlier matching record.
