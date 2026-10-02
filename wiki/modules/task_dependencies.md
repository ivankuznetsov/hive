---
title: Task dependencies
type: module
source: lib/hive/dependencies.rb, lib/hive/dependency_admission.rb, lib/hive/dependency_snapshot.rb, lib/hive/task_workspace/dependency_component.rb, lib/hive/repository_identity.rb, lib/hive/plan_frontmatter.rb
created: 2026-06-18
updated: 2026-10-02
tags: [task, dependencies, admission, status, daemon, repository]
---

**TLDR**: A task has one authoritative `depends_on` declaration in `meta.yml`,
either one task reference or a nonempty flat list of references. Scalars retain
the configured dependency gate and same-project branch stacking; lists are
scheduling-only, always branch from the project default, and require every
prerequisite to reach `9-done`. One shared fail-closed validator returns clear,
benign wait, or admission error for status, daemon, `hive run`, and forward
`hive approve`. Invalid or indeterminate evidence never becomes “no
dependency.”

## Declaration shape and grammar

Each reference is a same-project slug or numeric id, or an explicit
`project:slug`. A list preserves declaration order and shape, including a
singleton array:

```yaml
depends_on: api-task-260716-abcd       # same project by slug
depends_on: 42                         # same project by numeric id
depends_on: api:api-task-260716-abcd   # exact enrolled project + slug
depends_on:                            # every reference is required
  - api-task-260716-abcd
  - web:web-task-260716-ef01
```

`Hive::Dependencies.parse_reference` is the single reference parser and
`normalize_declaration` preserves whether the declaration was scalar or a
list. A bare reference never searches other projects. Lists must be nonempty
and flat; exact duplicate references are removed without collapsing a list to
a scalar. Mappings, blank entries, nested arrays, multiple separators, gate
suffixes, and cross-project numeric ids are invalid. An explicit cross-project
edge is scheduling-only. A same-project scalar retains the existing
stacked-branch and declared-revision behavior; every list, including
`depends_on: [one-task]`, is scheduling-only.

## Evidence and strict reads

`meta.yml` is authoritative. `TaskMeta.read_for_admission` distinguishes an
absent legacy sidecar from unreadable YAML, a non-mapping document, and an
invalid `depends_on`. General display code may still use the tolerant reader,
but admission never does. Metadata mutators refuse to rewrite corrupt input,
so id/display-name backfill cannot erase damaged dependency evidence. The
strict reader rejects duplicate top-level `depends_on` keys before YAML's
last-key-wins behavior can hide one of two declarations.

`plan.md` may repeat the assertion in top-level YAML frontmatter:

```yaml
---
depends_on: api:api-task-260716-abcd
---
```

No frontmatter, or frontmatter without `depends_on`, is valid. When present,
the plan value must parse with the same scalar-or-list grammar and normalize to
exactly the metadata value, including scalar-versus-list shape. A plan-only
assertion, mismatch, or malformed frontmatter is an admission error. Duplicate
top-level `depends_on` keys are invalid here too. Frontmatter scanning stops at
its closing delimiter and is capped at 64 KiB, so admission never reads an
unbounded plan body. Hive never scans plan prose for prerequisites.

This cross-check closes the ordering failure observed in the Honeycomb work:
the plan named a prerequisite that scheduling metadata did not carry. The
repository-identity check below closes the separate task-1854 provenance
failure where a referenced task number appeared under the wrong repository.

## Multi-project resolution and repository identity

`hive init` stores the enrolled project's normalized `origin` identity in the
global project registry. Common SSH and HTTPS spellings normalize to the same
host/path; incidental `.git` and trailing slashes are removed. Local-path
remotes normalize without network access. Host and repository path remain
significant.

For `project:slug`, admission resolves the exact enrolled project name and
compares its stored identity with the current repository's live `origin`
before trusting its task snapshot. A missing identity, unknown project, or
stored/live mismatch is held. Repositories without an origin may remain
enrolled and use same-project dependencies; identity is required only when
they participate as an explicit cross-project target. Hive does not guess or
auto-repair repository identity. Live Git lookups run only for projects named
by explicit cross-project edges, with a two-second process-group deadline and
TERM-to-KILL cleanup; same-project-only snapshots spawn no Git lookups.

Each admission invocation snapshots every enrolled project, its tasks, and
its own workflow descriptors. Qualified `[project, slug]` identities and
same-project numeric ids are indexed without using the global task resolver.
Routine active projections build a new immutable context from current active
task metadata, then recursively exact-load only missing dependency references
from terminal history. Exact slug references read the one matching folder;
same-project numeric references use the control plane's registered ID-to-slug
mapping, scoped to the project's state root. They check that slug across stage
folders and verify the current metadata ID, so an observed path that predates a
stage move does not cause a miss and a replacement folder cannot satisfy the
old identity. This reads no unrelated task metadata for registered IDs.
Older or never-run tasks without a registered subject retain metadata discovery
as a compatibility fallback; the lookup does not create or migrate a database. Loaded prerequisites preserve their workflow, dependency edge,
validation error, and project repository identity, including transitive chains,
without retaining or periodically refreshing a fleet archive cache. Bounded
Watch projections use the same closure builder from an exact set of selected
roots, so post-selection polling neither scans unrelated active tasks nor
replaces valid dependency verdicts with the daemon fast-tick hold.
These targeted contexts keep the complete enrollment index for unknown,
duplicate, and repository-identity checks, but load project admission policy
only for the selected roots and reachable prerequisites. A context-local cache
shares each project config across root and fallback reads; reachable policy
errors and gate stages populate the completed immutable context. Full
admission and mutation-time revalidation still read current policy.
Duplicate or ambiguous identities fail closed. Full-chain walking follows
every scalar or list edge, detects missing tasks, self-reference, corrupt
upstream nodes, and cycles, and reports a cycle as an ordered qualified path
including the repeated closing node. Creation rejects any resolvable cycle or
self-reference before publishing the new task; admission repeats the complete
check against current disk state. Cycle bookkeeping and immutable-context
verdicts are indexed and memoized, so one active projection evaluates shared
dependency tails once instead of rewalking them for every row. Each task folder's
device/inode identity is checked before and after strict reads; a concurrent
stage move invalidates that snapshot instead of retaining the enumerated old
stage after an `ENOENT` race.

## Gate and three verdicts

For a scalar declaration, the depending project's `dependency_gate_stage` is
authoritative. It defaults to `8-finalize`; `9-done` is the only other
supported value. Every edge in a list instead has the fixed `9-done` gate,
regardless of project configuration. Each prerequisite's own workflow must
contain both its current stage and its required gate. A list edge whose
workflow cannot reach `9-done` fails with `dependency_gate_unreachable` and
remediation to use a compatible workflow or correct erroneous workflow
metadata; changing `dependency_gate_stage` cannot make that list reachable.

Admission returns exactly one verdict:

| Verdict | Meaning | Status shape |
|---|---|---|
| Clear | no dependency, or every valid prerequisite at/after its gate | `blocked: false`, singular wait fields null, `unmet_dependencies: []`, `admission_error: null` |
| Wait | one or more valid prerequisites below their gates | `blocked: true`; scalar rows populate `blocked_by`/`dependency_stage`, while list rows keep those singulars null; `unmet_dependencies` contains every remaining blocker in declaration order |
| Admission error | invalid, inconsistent, or indeterminate evidence | `blocked: true`, singular wait fields null, action `admission_error`, no suggested command, structured `admission_error`; any independently observed blockers remain in `unmet_dependencies` |

Each `unmet_dependencies` entry contains `reference`, resolved `blocked_by`,
`dependency_stage`, and `required_gate`. `hive-status.v9` and
`hive-operational-status.v5` also expose `dependency_base_mode`: `stacked` only
for a resolvable same-project scalar and `default` otherwise. The array is the
authoritative fan-in explanation; scalar singulars remain compatibility
projections and are always null for list declarations.

The admission-error object contains exactly `reason_code`, `offending_ref`, and
`safe_correction`. The closed reason set is:

- `dependency_metadata_unreadable`, `dependency_metadata_invalid`,
  `dependency_reference_invalid`
- `dependency_task_missing`, `dependency_self_reference`, `dependency_cycle`
- `dependency_gate_unknown`, `dependency_gate_unreachable`
- `dependency_project_unknown`, `dependency_repository_identity_missing`,
  `dependency_repository_mismatch`
- `plan_dependency_invalid`, `plan_dependency_missing`,
  `plan_dependency_mismatch`
- `dependency_validation_failed` (unexpected fail-closed backstop)

Safe corrections describe the smallest known repair. They do not include a
command unless Hive can prove it is valid for that state.

## Enforcement boundaries

`hive status` builds one immutable context and is the canonical snapshot for
the daemon and TUI. Status still reports invalid admission after a raw
filesystem move into a dispatchable stage. Arbitrary `mv` itself is outside
Hive's preventable boundary.

The daemon gives admission errors precedence over stage/action policy, logs
the structured fields, drops any stale merge watch, and spawns nothing.
Ordinary waits also suppress merge polling, including a configured `9-done`
gate. Id/display-name backfill skips admission-error rows and uses strict
metadata reads. File-backed dispatch requests for run/advance/archive verbs
are checked against the same tick's status row before spawn and remain queued
on a dependency wait or admission error. `hive markers ...` repair requests
are deliberately exempt so an operator can repair stale/corrupt marker state.
A full dispatch-request scan constructs one immutable admission context for
recovery generation validation. Its indexed verdicts are reused across queued
requests; per-task state files and task identity are still revalidated under
each task lock. Fingerprints resolve the task's project from the context's path
index, preserving the same zero/duplicate-enrollment payload as the uncached
path without rescanning the fleet.
A task-local admission error exits 78 without dropping the entire enrolled
project from daemon scheduling.

`hive run` re-snapshots under the task lock before config, rebase, worktree, or
runner side effects. Forward `hive approve` re-snapshots inside the commit and
task locks immediately before moving. `--force` bypasses only terminal-marker
validation, never admission. Same-stage no-ops and backward approvals remain
available for repair.

Manual waits raise retryable `Hive::DependencyWaitError` (exit 75); admission
errors raise non-retryable `Hive::DependencyAdmissionError` (exit 78). JSON
errors use `dependency_wait` or `admission_error` and carry the three structured
fields. Workflow verbs inherit both checks through their composed approve/run
calls.

## Stacked branches

A valid same-project scalar continues to supply the prerequisite slug to
`DependencySnapshot.stacked_base`. Execute resolves the base from the remote
branch, then local branch, then default branch under the existing placeholder
preservation rules. Open-PR uses the prerequisite base only while that remote
branch exists. Explicit cross-project scalars and all lists—including
singleton arrays—return no stacked base and report `dependency_base_mode: default`.

## Bounded task-workspace component

`Hive::TaskWorkspace::DependencyComponent` explains the target's ancestors and
transitive descendants without creating a second dependency model. It reuses
the `DependencyAdmission::Context` and task metadata rows already collected by
the status snapshot, builds a reverse index under a semantic dependency
fingerprint, and never falls back to another fleet directory traversal. A
snapshot that lacks enough rows returns a partial-project sentinel.

Traversal is capped at 32 projects, 10,000 scanned metadata entries, 100 nodes,
200 edges, depth 20, 4 MiB, and two seconds. Missing or inaccessible nodes,
cycles, blocked chains, and each exhausted cap remain explicit nodes/edges or
truncation diagnostics. Same-repository stack evidence compares immutable
worktree repository/base branch/base OID with separately observed local refs;
cross-project dependencies remain scheduling-only. No component node triggers
a Git fetch or GitHub query.

The compact view is a deterministic rooted spanning forest: every task renders
once and non-tree, cyclic, or back edges become labeled cross-references. An
always-present semantic node/edge table is authoritative for the complete
bounded relationship set. See [[modules/task_workspace]].

## Recovery

Inspect `hive status --operational --json` or the TUI's admission text, then repair the named
`meta.yml`, `plan.md`, project enrollment, remote, workflow, or gate. Do not
delete dependency metadata merely to clear the row unless removing the edge is
the intended model change. For corrupt state that must move out of a forward
stage, use a backward `hive approve --to ...`; forward run/approval resumes only
after admission becomes clear.

Array metadata is a no-downgrade boundary. Upgrade every Hive CLI, daemon, web
reader, and other long-lived consumer to the release that understands
`hive-status.v9` / `hive-operational-status.v5`, restart those processes, and
only then create list declarations. Do not write an array and later run an
older process: older readers fail closed, and operators must preserve every
listed prerequisite while completing the upgrade rather than rewriting the
array as a scalar to make the old reader proceed.

## Tests

- `test/unit/dependencies_test.rb`, `task_meta_test.rb`, and
  `plan_frontmatter_test.rb` pin the declaration grammar and strict evidence.
- `test/unit/dependency_admission_test.rb`, `dependency_snapshot_test.rb`, and
  `repository_identity_test.rb` pin graph, gate, workflow, and remote identity.
- `test/unit/task_workspace/dependency_component_test.rb` pins bounded reverse
  traversal, cycles, missing nodes, divergence, truncation, and deterministic
  forest/table parity without additional scans or remote calls.
- `test/integration/dependency_admission_test.rb` reproduces anonymized
  plan-only ordering and cross-project repository-mismatch failures across
  status and manual boundaries, plus a nine-prerequisite fan-in proving exact
  remaining blockers, fixed `9-done`, scalar configured gates, force
  non-bypass, and eventual release.
- status/TUI, daemon, command, and schema suites pin the same three verdicts at
  every consumer.

## Backlinks

- [[modules/task]] · [[commands/status]] · [[modules/daemon]]
- [[commands/run]] · [[commands/approve]] · [[commands/new]] · [[stages/plan]]
- [[modules/worktree]] · [[stages/execute]] · [[stages/open-pr]]
- [[modules/task_workspace]]
