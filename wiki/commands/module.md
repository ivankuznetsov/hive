---
title: hive module
type: command
source: bin/hive, lib/hive/cli.rb, lib/hive/commands/module.rb, lib/hive/commands/module/, lib/hive/module_package/, lib/hive/modules/, schemas/hive-module-*.json
created: 2026-07-22
updated: 2026-07-22
tags: [command, modules, honeycomb, status, doctor, dry-run, security]
---

**TLDR**: Queued branch head `071d0d71` adds a project-local `hive module`
surface for reviewed Honeycomb module lifecycle changes and read-only
operations. Its U5 slice makes `list`, `inspect`, and `status` share one
immutable redacted projection, adds a no-repair `doctor`, and evaluates
synthetic events through the production trigger evaluator with `dry-run`.
This commit is not an ancestor of the refresh branch; the current default
branch has no `lib/hive/module_package/` or `lib/hive/modules/` tree. Treat the
commands below as a queued contract, not installed current-main behavior. See
[[gaps]].

## Command surface

| Command | Behavior | JSON schema |
|---------|----------|-------------|
| `hive module install SOURCE` | Resolve a reviewed package, build the exact configuration/grant preview, then install it. | `hive-module-lifecycle.v1` |
| `hive module update NAME` | Resolve `honeycomb/NAME`, compare it with the active generation, and apply the reviewed update. | `hive-module-lifecycle.v1` |
| `hive module enable NAME` / `disable NAME` | Preview and apply the installed selection-state change. | `hive-module-lifecycle.v1` |
| `hive module uninstall NAME` | Tombstone the selection while retaining the previous generation and history for inspection. | `hive-module-lifecycle.v1` |
| `hive module list` | List installed modules through the same redacted status projection used by `status`. Tombstones are excluded. | `hive-module-list.v1` |
| `hive module inspect NAME` | Inspect one installed module or retained uninstall history. | `hive-module-status.v1` |
| `hive module status [NAME]` | Inspect one name, or every installed/tombstoned module when the name is omitted. | `hive-module-status.v1` |
| `hive module doctor NAME` | Return the shared status plus bounded `ok`/`warning`/`error` checks without repairing state. | `hive-module-doctor.v1` |
| `hive module dry-run NAME --event EVENT` | Build a synthetic event and run the production trigger/admission evaluator without locks, cursors, journals, runs, or attempts. | `hive-module-dry-run.v1` |

Lifecycle configuration uses repeatable `--setting NAME=VALUE`,
`--hook ID=enabled|disabled`, and `--grant CATEGORY=VALUE` choices. Mutations
are preview-bound: `--dry-run` returns a time-limited receipt; a JSON or other
non-interactive apply requires that exact `--receipt` plus `--yes`, while an
interactive apply still asks for confirmation. A matching already-applied
receipt returns `already_current` instead of mutating again.

Module event dry-run requires `--event`. `schedule` also requires the exact
five-field UTC cron binding in `--schedule`; `--occurred-at` accepts an ISO
8601 timestamp. Without it, evaluation uses the current UTC time. The command
requires the project root to match one registered project so the synthetic
event carries the real project id/name. Omitting a hook evaluates every hook
in the retained configuration.

The wrapper's pre-dispatch JSON usage routing is schema-specific: `list` uses
`hive-module-list`, `inspect`/`status` use `hive-module-status`, `doctor` uses
`hive-module-doctor`, `dry-run` uses `hive-module-dry-run`, and lifecycle
subcommands use `hive-module-lifecycle`. Missing/unknown subcommands and
missing names exit with the usage code rather than being reported as task-path
errors.

## Shared redacted status

`Hive::Modules::Inspector` joins atomically published selection/configuration
state with hook cursors, immutable decisions, durable module-hook attempts,
run snapshots, retry state, and bounded artifact references. It returns a
frozen `Hive::Modules::Status` whose lifecycle is one of:

- `active`
- `activating`
- `corrupt`
- `disabled`
- `failed_activation`
- `uninstalled_history`

The projection includes active/previous package provenance, selection epoch
and high-water timestamp, configuration/generation/activation integrity,
grants plus their digest, hook bindings and next scheduled UTC trigger, latest
decision/attempt summaries, retry/failure state, at most 50 artifact
references, and whether retained history exists.

Secret values are never returned. A secret setting exposes `value: null`, its
environment binding name, and a boolean availability result; non-secret
settings expose their value and no binding. Raw configuration bytes,
environment values, logs, stderr, and malformed source bytes are outside the
projection. A read/parsing failure becomes a bounded `corrupt` row with
`failure_reason=state_corrupt` rather than leaking the offending bytes.

`list`, `inspect`, `status`, and `doctor` all consume this same projection, so
CLI and future web consumers do not implement separate redaction rules.

## Read-only boundaries

`ManagedStore#inspect_selection(s)` and `#inspect_hooks` deliberately bypass
transaction reconciliation and the mutation lock. Selection, configuration,
and hook files are atomically published, so a reader sees old or new bytes and
can report an interrupted activation without healing it or creating a lock
file. The inspector also opens the attempt store and decision journal with
directory creation disabled.

`doctor` checks:

- selection readability;
- configuration digest and generation presence;
- activation barrier/journal residue;
- required secret-binding availability; and
- complete descriptor/configuration/grant snapshots for nonterminal runs.

Activation residue is a warning; missing integrity or required runtime inputs
is an error. `healthy` is false only when at least one error is present.
Doctor never clears a barrier, reconciles a transaction, repairs a snapshot,
or writes a directory.

`dry-run` uses `Modules::Dispatcher#dispatch(..., dry_run: true)`. It skips the
per-hook lock, reads selections without reconciliation, projects a decision
with `decision_id: null`, and does not advance the cursor, append the decision,
persist a run, or call the attempt dispatcher. For a schedule event, the
supplied binding enters the synthetic event and the production evaluator
compares it with the hook's manifest-approved schedules. The bounded UTC cron
planner separately supplies status's next trigger and live event-ledger
missed-window coalescing.

## State model

The queued branch stores module package and runtime state beneath the project
state root:

```text
<hive_state_path>/
├── modules/<name>/
│   ├── selection.json
│   ├── generations/<source-commit>/
│   ├── configurations/<sha256>.json
│   ├── diagnostics/failed-activation.json
│   └── runtime/
│       ├── hooks.json
│       ├── activation-barrier.json
│       └── runs/<run-id>.json
└── module-runtime/
    └── decisions/dec-<sha256>.json
```

Successful activation now removes stale `failed-activation.json` evidence
after the transaction commits. Failed activation retains only the bounded
reason, safe error class, and timestamp. Uninstall keeps the prior generation
and selection tombstone so status and doctor can distinguish retained history
from a never-installed name.

## Verification

The U5 commit adds focused command/schema/status/doctor/dry-run tests. They pin
cross-command projection equality and redaction, schema registration, next
scheduled trigger calculation, read-only interrupted-activation inspection,
bounded corrupt-state output, missing binding/incomplete snapshot diagnosis,
and byte-for-byte filesystem stability across doctor/dry-run calls. Broader
module-package, lifecycle, dispatcher, event-ledger, schedule, and decision
journal tests exist in the same queued branch ancestry; default-branch and
installed-package verification remain open in [[gaps]].

## Backlinks

- [[commands]]
- [[cli]]
- [[architecture]]
- [[state-model]]
- [[testing]]
- [[gaps]]
