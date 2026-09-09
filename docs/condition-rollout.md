# Generation-scoped condition rollout

Generation-scoped conditions are an execute-stage safety system. The durable
`task-journal.jsonl` journal is authoritative and Hive folds it directly in
memory. Task markers remain a reversible compatibility surface. Inbox,
brainstorm, plan, open-PR, review, artifacts, finalize, and archive transitions
remain marker-authoritative in this increment.

## Authority modes

Existing projects default to marker authority:

```yaml
conditions:
  authority: markers
  stages: {}
```

Only `4-execute` can opt into another mode:

```yaml
conditions:
  authority: markers
  stages:
    4-execute: shadow       # marker action wins; append parity audits
    # 4-execute: conditions # condition gate wins after explicit promotion
```

`markers` follows the legacy action. `shadow` evaluates both paths after the
same reconciliation boundary, follows the marker action, and records any
divergence. `conditions` follows the folded condition gate and still writes the
compatibility marker. Changing mode never deletes the journal, evidence, or
marker history. Hive never changes this configuration itself.

A legacy task receives one generation-0 baseline only at a mutating execute
boundary. Status reads do not create it. Even if configuration says `shadow`
or `conditions`, marker authority remains effective until the first real
supervised attempt supplies the durable attempt ID and numeric input epoch.

## Inspecting a task

Use the public operational projection to find the task's condition warning,
owner, reasons, and guarded action, then inspect that task's semantic workspace:

```bash
hive status --operational --json |
  jq '.tasks[] | select(.identity.project == "PROJECT" and .identity.slug == "SLUG") |
  {identity, position, state, blocker_owner, reasons,
   condition_warning: .evidence.condition_warning, action}'
hive task SLUG --project PROJECT --json
```

Detailed condition arrays and generation joins remain scheduler internals; do
not script them through Hive's hidden task-graph transport. If they need to
become an operator contract, add them to a bounded, versioned command response.

`condition_gate.status` is `eligible`, `blocked`, or `reconcile_required`.
Diagnostics distinguish `pending`, `unsatisfied`, and `unverifiable` facts.
`AwaitingHuman=satisfied` is an active inhibitor; it is not a positive
requirement. The current and historical condition arrays preserve the reason,
attempt, generation, commit revision, evidence, and supersession provenance.

Status is read-only: it takes a shared lock, reads a bounded journal, validates
each JSON line and the hash chain, and folds the records in memory. Historical
replay never queries SQLite. A missing journal is an empty stream; malformed,
oversized, or incomplete history fails that task closed.
Status does not inspect git/GitHub or append a baseline/audit.

Blocked condition rows carry a reason-specific `next_action` even when the
compatibility marker is stale. A blocked `hive run --json`, `hive approve
--json`, or workflow-verb transition returns the same `condition_gate` and
`next_action` instead of requiring prose parsing. `hive approve --force`
records an idempotent `operator_action` before it advances; a failed audit
append fails the override closed. Status exposes the latest 20 such overrides
as `condition_overrides`, while the journal retains the complete history.

## Invalid history

There is no derived snapshot to repair. For `task_history_invalid`, fix the
named journal problem or restore `task-journal.jsonl` from source control or a
backup. For `condition_unverifiable`, fix the named evidence source (for
example, restore the worktree or repair git access) and rerun the execute
boundary. Hive fails closed rather than inventing history or looping.

## Shadow audit and promotion

Stay in `shadow` until all of these are true:

- at least 100 categorized execute transitions;
- commit success, research success, no-change, agent-loss, and operator-repair
  each have at least one sample;
- zero unexplained mismatches;
- the divergence allow-list is empty;
- every projection golden fixture is green, including task 1849.

Run the golden replay before evaluating promotion:

```bash
bundle exec ruby -Itest test/unit/task_projection_replay_test.rb
```

The `shadow_audit` status object reports counts and readiness evidence but
cannot mutate configuration. `parity_ready` covers journal volume/category/
drift/allow-list criteria; `ready` additionally requires externally supplied
green fixture evidence and therefore remains false in the pure per-task status
projection. Classify a mismatch from the journal evidence;
fix the policy/reconciler/projection cause rather than adding a permanent
allow-list entry. When the complete bar is green, an operator explicitly edits
the project config to `4-execute: conditions` and observes the next transitions.

## Rollback

Set `4-execute` back to `markers` and reload the next command/daemon tick:

```yaml
conditions:
  authority: markers
  stages:
    4-execute: markers
```

Marker gating resumes immediately. Journal history and snapshots remain
available for diagnosis and a later shadow retry. Compatibility markers keep
being written in every mode, so rollback needs no history rewrite or repair.

## Fixture contract

Incident bundles live under `test/fixtures/incidents/<incident>/`. Each
`manifest.json` pins input digests, sanitization notes, synthetic event IDs,
durable attempt metadata, and the expected canonical projection. Synthetic
condition-era records must carry `provenance.synthetic: true` and a source;
they must never be presented as production observations.
