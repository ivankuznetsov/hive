# Generation-scoped condition rollout

Generation-scoped conditions are an execute-stage safety system. The durable
`events.jsonl` journal is authoritative; `task-projection.json` is a validated,
disposable materialized view; task markers remain a reversible compatibility
surface. Inbox, brainstorm, plan, open-PR, review, artifacts, finalize, and
archive transitions remain marker-authoritative in this increment.

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
divergence. `conditions` follows the projected gate and still writes the
compatibility marker. Changing mode never deletes the journal, snapshot,
evidence, or marker history. Hive never changes this configuration itself.

A legacy task receives one generation-0 baseline only at a mutating execute
boundary. Status reads do not create it. Even if configuration says `shadow`
or `conditions`, marker authority remains effective until the first real
supervised attempt supplies the durable attempt ID and numeric input epoch.

## Inspecting a task

Use the public status contract:

```bash
hive status --json | jq '.projects[].tasks[] |
  select(.stage == "4-execute") |
  {slug, action, marker, condition_task_generation, commit_generation,
   current_attempt, condition_gate, condition_migration,
   condition_warning, shadow_audit}'
```

`condition_gate.status` is `eligible`, `blocked`, or `reconcile_required`.
Diagnostics distinguish `pending`, `unsatisfied`, and `unverifiable` facts.
`AwaitingHuman=satisfied` is an active inhibitor; it is not a positive
requirement. The current and historical condition arrays preserve the reason,
attempt, generation, commit revision, evidence, and supersession provenance.

Status is read-only: it validates the snapshot cursor/hash and replays the
journal in memory when the snapshot is missing, stale, corrupt, or from an
unsupported schema. It does not inspect git/GitHub, append a baseline/audit,
or publish a repaired snapshot.

## Repairing a snapshot

Deleting a snapshot is safe because no authoritative state lives only there:

```bash
rm /absolute/task/folder/task-projection.json
```

The next mutating execute reconciliation republishes it. To rebuild immediately
from the journal without observing live state, run from a Hive checkout:

```bash
bundle exec ruby -Ilib -rhive -rhive/task_projection/store \
  -e 'Hive::TaskProjection::Store.new(task_folder: ARGV.fetch(0)).rebuild!' \
  /absolute/task/folder
```

For `condition_unverifiable`, fix the named evidence source first (for example,
restore the worktree or repair git access) and rerun the execute boundary. Hive
performs one inline reconciliation; persistent missing/unverifiable evidence
fails closed rather than looping or advancing.

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
cannot mutate configuration. Classify a mismatch from the journal evidence;
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
