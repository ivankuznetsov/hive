# Workflow actions

## Prefer the scheduler for enrolled work

Check operational status before dispatch. When a project is daemon-enabled, the daemon owns ordinary automatic progression and task action descriptors are suppressed. Watch or report the current gate instead of racing it with a duplicate direct command.

When the user explicitly requests direct workflow work, discover the exact current syntax with `hive help <verb>` and prefer structured output where supported. Common coding-flow verbs are:

```bash
hive new PROJECT "task description"
hive brainstorm SLUG --project PROJECT --json
hive plan SLUG --project PROJECT --json
hive develop SLUG --project PROJECT --json
hive review SLUG --project PROJECT --json
hive artifacts SLUG --project PROJECT --json
hive finalize SLUG --project PROJECT --json
hive archive SLUG --project PROJECT --json
```

Hive can also run project-authored workflows. Inspect them with `hive workflow list --json`; do not assume every task uses the coding stage names.

Reviewed project-local modules use one shared status and lifecycle contract:

```bash
hive module list --json
hive module status --json
hive module inspect NAME --json
hive module doctor NAME --json
hive module dry-run NAME --event schedule --schedule '*/10 * * * *' --json
```

These commands are read-only. Module dry-run evaluates the production trigger
logic without persisting an event, decision, attempt, cursor, claim, artifact,
or worker. That is intentionally different from the legacy Patrol commands
described below.

Installation and change are preview-bound. First run the exact lifecycle
command with `--dry-run --json`, review every setting, hook, binding, and
individual grant, then apply only with the matching receipt and explicit human
approval. Never infer a missing non-interactive choice or grant.
`hive module migration status --json` is the exact read-only migration
diagnostic; `migration report`, `cutover`, and `rollback`
are administrative, human-only transitions and are not `hive act` actions.

For reviewed Honeycomb workflows, preview the exact no-write operation first:

```bash
hive workflow install honeycomb/NAME --dry-run --json
hive workflow update NAME --dry-run --json
hive workflow remove NAME --dry-run --json
```

Only after the user approves that output, run the matching operation with
`--yes --json`. Permission growth or another high-risk change requires separate
approval before `--allow-escalation`; ordinary install/update consent does not
authorize escalation.

Patrol is different: `hive patrol ... --dry-run` and
`hive refactor-patrol ... --dry-run` still launch agents, consume provider
subscription capacity, and may persist scan state. Show the project, configured
patrol mode, and PR-creation potential, then obtain confirmation before a manual
patrol start. A previously approved daemon schedule carries its existing
consent; observe it without re-confirming each tick.

## Execute a closed routine recommendation

An operational task row may contain an `action` with:

- `action_id`
- exact `target`
- opaque `observation_token`
- `risk_class: routine_idempotent`
- `confirmation_required: false`

Only that closed shape authorizes agent execution:

```bash
hive act ACTION_ID PROJECT:SLUG --observation OBSERVATION_TOKEN --json
```

Use the action immediately from the same fresh snapshot. Hive re-resolves and revalidates identity, stage, marker, action, and task generation under its normal mutation lock. A stale token is a request to re-snapshot, not a reason to bypass the guard. `hive act` never accepts shell text or raw argv from status.

After success or failure, run `hive status --operational --json` again and report the new state. Do not chain an unbounded sequence of actions from one snapshot.

## Verify completion

`completion_ready` means a completion boundary is ready for its owner; it does not by itself prove archive or publication. Verify the requested end state explicitly:

- For a task lifecycle, observe a matching archived identity or descriptor-defined terminal completion.
- For a PR, verify current GitHub state and checks when the user asks for PR completion.
- For a benchmark, distinguish generated, judged, pending, and publishable results.
- For a release or deployment, stop at local validation unless the user separately authorizes that external step.
