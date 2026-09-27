---
title: hive receipt
type: command
source: lib/hive/commands/receipt.rb, lib/hive/command_receipt_{store,pruner,maintenance,capacity}.rb
created: 2026-09-27
updated: 2026-09-27
tags: [command, idempotency, receipts, sqlite, maintenance]
---

**TLDR**: Hive can give the bounded C4 mutation surface durable, optional
idempotency keys. A matching retry replays the original result without
resolving the task again. Receipt maintenance is explicit, generation-fenced,
and preview-first. Only prune accepts its own idempotency key.

## Installation and enablement

The additive receipt schema is not part of ordinary setup. A production build
must name a published and retained compatibility package before this succeeds:

```sh
hive setup --install-command-receipts
# unattended consent:
hive setup --yes --install-command-receipts
```

This changes the one shared host control-plane database for every project and
service using it. All writers must be provably stopped. `--yes` alone never
installs the extension. `--no-bootstrap` is diagnosis-only and takes precedence
over the opt-in flag. Ordinary later setup retains an installed extension.

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

# Restore-authority evidence is bounded JSON and must account for every effect.
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
results. Other principals cannot enumerate namespaces or foreign operations.

```sh
hive receipt prune --json --limit 100
hive receipt prune --namespace-id UUID --json
```

Relocation or a re-clone with a deliberately abandoned prior identity is
explicit and cannot recover old keys in the new store:

```sh
hive receipt enroll --project PROJECT --new-identity \
  --previous-identity UUID --expected-generation 0 --json
hive receipt enroll --project PROJECT --new-identity \
  --previous-identity UUID --expected-generation 0 --confirm --json
```

## Pins and trust

Automated callers acquire a pin with a caller-declared absolute
`retry_horizon_expires_at`. The timestamp is evidence, not a lease: passage
never expires or releases the pin. An identical acquisition may replay after
the horizon. If the pin is gone and its persisted horizon has elapsed, the
caller must close the intent and begin a new acquisition identity with a new
future horizon; it may not repeat an unknown effect.

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

## Backlinks

- [[commands/setup]]
- [[operating]]
- [[state-model]]
