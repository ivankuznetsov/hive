---
title: hive receipt
type: command
source: lib/hive/commands/receipt.rb, lib/hive/command_receipt_{store,pruner,maintenance,capacity,ledger}.rb
created: 2026-09-27
updated: 2026-11-02
tags: [command, idempotency, receipts, sqlite, maintenance]
---

**TLDR**: Hive can give the bounded C4 mutation surface durable, optional
idempotency keys. A matching retry replays the original result without
resolving the task again. Receipt maintenance is explicit, generation-fenced,
and preview-first. Only prune accepts its own idempotency key.

## Installation and enablement

For the retained uncertainty and historical evidence, see [Command receipt activation boundaries (2026-09-27)](#command-receipt-activation-boundaries-2026-09-27).

The additive receipt schema is not part of ordinary setup. A production build
must name a published and retained compatibility package before this succeeds:

```sh
hive setup --install-command-receipts
# unattended consent:
hive setup --yes --install-command-receipts
```

This changes the one shared host control-plane database for every project and
service using it. All writers, including a foreground `hive web`, must be
provably stopped. `--yes` alone never
installs the extension. `--no-bootstrap` is diagnosis-only and takes precedence
over the opt-in flag. Ordinary later setup retains an installed extension.

Without the extension, keyed `hive new` (the only keyed command that predates
receipts) falls back to per-project TaskCapture idempotency with a one-line
stderr notice; see [[commands/new]]. Keyed `answer`, `approve`, stage actions,
`act`, `archive`, and `receipt prune` only ever existed with receipts and still
fail CONFIG (`Hive::CommandReceiptsNotInstalled`) until it is installed.

New keyed intake is independently disabled by default. After verification,
set this in the canonical project `.hive-state/config.yml`; linked worktrees
use that same policy:

```yaml
command_receipts:
  keyed_intake_enabled: true
  nonterminal_limit: 1000
  concurrency_limit: 32
  byte_admission_limit: 67108864
```

Disabling intake does not disable replay, recovery, finalization, or authorized
maintenance. Enabling it never installs the schema.

## Protected mutations

Optional `--idempotency-key KEY` support is bounded to `new`, answer writes,
`approve`, `act`, descriptor-backed stage verbs, and targeted `archive`.
Answer inventory and archive listing remain read-only. Receipt prune is the
only maintenance mode accepting a key. The key is nonempty UTF-8, at most 512
bytes, and is exclusive across principals within a project namespace.

The public outcomes are `COMMAND_CONFLICT` (20), `COMMAND_IN_PROGRESS` (21),
and `COMMAND_UNRESOLVED` (22). Exit 22 represents both pending uncertainty and
the terminal `settled` state. Automated callers **must** consume `--json` and
inspect `state` plus the typed reason. A settled receipt reports
`command_original_result_unavailable`, is never retry-eligible, and does not
claim business success.

A deterministic rejection before effect submission is stored as `failed` with
validated whole-effect non-application and can feed the shared successor
allocator. Lock contention before submission records an orderly `aborted`
generation that the identical request can reacquire; it never becomes a
durable result or permanently burns the key. Every effect submission,
dispatch-context bind, and observation is fenced by the receipt's ownership
generation and principal, so a reclaimed owner cannot append evidence to its
successor's execution.

Untemplated JSON success and failure envelopes retain the canonical typed
payload for replay. Display mode remains a caller choice: text-first durable
stage execution is captured as typed JSON internally, and a text caller never
receives a stored JSON failure merely because the original invocation used
JSON internally. If an applied effect's saved result is missing or corrupt,
replay returns `command_original_result_unavailable` instead of presenting the
loss as an in-progress command.

## Maintenance

All destructive commands preview by default. Repeat with `--confirm` only
after inspecting the fixed receipt or batch generation.

```sh
# Eligible terminal rows only: terminal_at older than 30 days, no active pin.
hive receipt prune --project PROJECT --json
hive receipt prune --project PROJECT --confirm --limit 100 --json

# One unresolved/aborted row; effects may have happened and retry stays forbidden.
hive receipt retire RECEIPT_ID --expected-generation G \
  --settle-without-result --reason TEXT --json
hive receipt retire RECEIPT_ID --expected-generation G \
  --settle-without-result --reason TEXT --confirm --json

# Reclassify one executing owner only after PID/start-time proof of death.
hive receipt retire RECEIPT_ID --expected-generation G \
  --orphaned-owner --reason TEXT --confirm --json

# Authoritative reconciliation evidence is bounded JSON and must account for every effect.
hive receipt retire RECEIPT_ID --expected-generation G \
  --evidence evidence.json --reason TEXT --confirm --json

hive receipt release-pin PIN_ID --expected-generation G --reason TEXT --json
hive receipt release-pin PIN_ID --expected-generation G \
  --force --reason TEXT --confirm --json

hive receipt abandon-batch BATCH_ID --expected-generation G \
  --reason TEXT --confirm --json
```

Installation owners can preview bounded namespace summaries without a project,
and can use `--namespace-id UUID` after a project has been forgotten. The
selector exposes IDs and generations needed for maintenance, not keys or saved
results. `maintenance_next_cursor` paginates the combined batch, pin, and
non-terminal receipt identities within the selected namespace. Other
principals cannot enumerate namespaces or foreign operations. Installation
owners receive effective installation limits, aggregate utilization, physical
page/freelist/WAL occupancy, and the 70/85 percent pressure band used by
admission diagnostics. Non-owners receive none of those installation or
physical-byte fields.

Non-owner project previews include only that principal's utilization and its
own active pins, unfinished batches, and non-terminal receipt identities. The
namespace intake gate is reported separately. Admission-time dead-owner probes
use separate durable namespace and installation cursors so a wider scan cannot
advance a namespace past its own oldest dead-owner candidate.

```sh
hive receipt prune --json --limit 100
hive receipt prune --namespace-id UUID --json
```

A successful evidence retirement can select only the original replay envelope
that the keyed command boundary persisted before attempting its final receipt
commit. A maintenance evidence file cannot supply or replace that result. It
also provides one reconciliation entry for every stored effect; each entry must
match the stored effect id, ordinal, identity digest, and an exact observation
already written by the authoritative task/provider reconciler. A self-consistent
caller-created result, a made-up observation string, a partial list, or an
unknown effect remains unresolved. Confirm-time generation and authority checks
still fence late owners and revoked installation-owner credentials.

When an authoritative task activity or GitHub publication state machine has a
safe continuation, an identical keyed retry may resume that state machine. It
re-observes the exact correlation and never treats a timeout or process exit as
proof that an external effect did not happen. If the command boundary saved the
original response but its final receipt commit was not acknowledged, the retry
finalizes and replays that saved response without running the command body.

Relocation or a re-clone with a deliberately abandoned prior identity is
explicit and cannot recover old keys in the new store:

```sh
hive receipt enroll --project PROJECT --new-identity \
  --previous-identity UUID --expected-generation 0 --json
hive receipt enroll --project PROJECT --new-identity \
  --previous-identity UUID --expected-generation 0 --confirm --json
```

Enrollment uses the same installation-owner authority predicate as destructive
receipt maintenance and repeats that authorization inside each identity write
transaction. Its audit records the authenticated principal, source, authority
basis, and peer address rather than synthesizing a local uid claim. The pending
enrollment row also retains that audit context before the marker is written, so
crash recovery cannot activate a replacement identity without the original
operator record.

## Pins and trust

Automated callers acquire a pin with a caller-declared absolute
`retry_horizon_expires_at`. The timestamp is evidence, not a lease: passage
never expires or releases the pin. An identical acquisition may replay after
the horizon. If the pin is gone and its persisted horizon has elapsed, the
caller must close the intent and begin a new acquisition identity with a new
future horizon; it may not repeat an unknown effect.

Fresh pins and failed-receipt successor allocations read the live namespace
policy, obey the intake gate, and reserve byte headroom atomically. Reacquiring
an existing pin remains available while intake is disabled so already-admitted
work can recover. Fresh admission requires the caller lifecycle's current
canonical project root and verifies that it still resolves to the receipt
namespace; the namespace schema does not persist or infer a project path.
Durable dispatch pins remain active after command success and close only when
the owning dispatch result is acknowledged. Active predecessor intents also
retain their successor allocation and referenced successor receipt during
prune. Pin previews and force-release audits report both retry-horizon and
local owner-liveness evidence; elapsed time alone never releases protection.

CLI and scheduler principals use the installation-scoped local uid. GitHub
principals use the numeric account id. Cross-principal web maintenance requires
both configured `web.github.owner` and its matching positive
`web.github.owner_id`. A login-only installation permits ordinary login but no
elevated maintenance until first authenticated owner admission records the id.
Before that enrollment, login reuse after rename, transfer, or deletion can
bind the account that acquired the configured login. Configure the intended
owner's verified numeric id before exposure.

`HIVE_WEB_LOCAL_LOOPBACK` trusts reachability of the loopback socket after
state-home custody validation; it does not authenticate the calling local
process with peer credentials. Any local process reaching that socket maps to
the installation-owner principal and can therefore claim/conflict with the
owner's keys. This increment exposes no web maintenance routes.

Maintenance audit rows record actor source, authority, peer address where
applicable, reason, and bounded evidence. They are write-only in this increment
and are deleted with the owning receipt by ordinary eligible prune. They are
not independent post-hoc accountability.

## Retention boundary

Confirmed prune deletes only `succeeded`, `failed`, or `settled` rows whose
immutable terminal time is strictly older than 30 days and which have no live
pin/reference. It never deletes prepared, executing, unresolved, or aborted
rows. SQLite pages become reusable; file shrinking is not promised. A storage
or lock failure returns a typed error and no success claim. Once a receipt is
actually pruned, Hive retains no tombstone and cannot promise replay/conflict
protection for a later retry.

The additive extension is accepted only when both its closed SQLite manifest
checksum and its single `command_schema_versions` ledger row match the runtime
version. Owner reclamation and maintenance lookup paths have dedicated indexes;
the bounded owner scan occurs outside the immediate write transaction.
Installation nonterminal, execution, and logical-byte admission reads a
trigger-maintained singleton aggregate instead of rescanning every enrolled
namespace. Completed maintenance-batch cleanup is bounded by the same prune
limit, and rejected keyed prune reservations are removed rather than retained
as an unbounded administrative backlog.

## Backlinks

- [[commands/setup]]
- [[operating]]
- [[state-model]]

## Known gaps

### Command-receipt external evidence gaps (2026-09-28)

#### Source S06, lines 104–116: Command-receipt external evidence gaps (2026-09-28)

Resolved for Tier A on 2026-09-28: the compatibility candidate was rebuilt
from a clean archive of baseline `f3de2561` with the current patch
(`82562752…`, whose 31-object inventory matches `CommandSchema::OBJECT_NAMES`
including the installation-wide capacity aggregate). The rebuilt candidate is
`ddc5ecca37a4fa67329ad022c546d03bee71bf6526f2180838ed32dc765971db`, and the
isolated rollback/re-upgrade drill was repeated against a fresh database. The
candidate read and wrote the extended base schema, the current runtime replayed
its terminal receipt without re-executing, and an altered extension failed
closed. The earlier `4ac48a4a…` candidate is superseded. Details are in
`docs/implementation/command-receipt-compatibility-proof.md`. Publication
remains a separate Tier B authorization boundary: no published coordinates
exist, and the candidate is not a distribution.

### Command-receipt C4 consumer mapping (2026-09-28)

#### Source S06, lines 117–126: Command-receipt external evidence gaps (2026-09-28)

The producer checkout still has no concrete hivedev C4 request/response
mapping, so local verification covers only the bounded Hive adapters. The
bounded-search record in `docs/command-receipts-c4-comparison.md` is attached
to the hivedev C4 consumer task `c4-implement-durable-command-operations-260923-9817`
(`.hive-state/stages/1-inbox/c4-implement-durable-command-operations-260923-9817/idea.md`)
by hivedev state commit `f54b9b998b4d9b83799283ef175d54e0cee5b2b2`. That
commit is on the local `hive/state` branch and has not been pushed to the
hivedev remote. The Hive follow-up tasks `hive:43362`, `hive:43363`, and
`hive:43364` link the record from their bodies (hive state commit `3cbb2e5e62`).

### Command receipt activation boundaries (2026-09-27)

#### Source S84, lines 1774–1785: Command receipt activation boundaries (2026-09-27)

- The compatibility rollback package remains a production-activation
  dependency; source support does not prove a published, retained package can
  be fetched.
- Receipt maintenance is CLI-only in this increment. There is no shipped web
  route for prune, retirement, pin release, batch abandonment, or enrollment.
- Project identity and receipt continuity cover one intact host database plus
  its bound marker. Multi-host continuity and decommission witnesses remain a
  follow-up.
- Terminal prune reclaims reusable SQLite pages. It does not guarantee that the
  database or WAL files shrink on disk.
