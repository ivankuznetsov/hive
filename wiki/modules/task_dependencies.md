---
title: Task dependencies
type: module
source: lib/hive/dependencies.rb, lib/hive/dependency_admission.rb, lib/hive/dependency_snapshot.rb, lib/hive/repository_identity.rb, lib/hive/plan_frontmatter.rb
created: 2026-06-18
updated: 2026-07-16
tags: [task, dependencies, admission, status, daemon, repository]
---

**TLDR**: A task may declare exactly one authoritative `depends_on` value in
`meta.yml`: a same-project slug or numeric id, or an explicit
`project:slug`. One shared fail-closed validator returns clear, benign wait, or
admission error for status, daemon, `hive run`, and forward `hive approve`.
Invalid or indeterminate evidence never becomes “no dependency.”

## Scalar decision and grammar

Hive deliberately retains one prerequisite rather than a general graph:

```yaml
depends_on: api-task-260716-abcd       # same project by slug
depends_on: 42                         # same project by numeric id
depends_on: api:api-task-260716-abcd   # exact enrolled project + slug
```

`Hive::Dependencies.parse_reference` is the single parser. A bare reference
never searches other projects. Cross-project numeric ids, lists, mappings,
blank values, multiple separators, and gate suffixes are invalid. An explicit
cross-project edge is a scheduling gate only: it never supplies a local
stacked-branch or PR base. Same-project dependencies preserve the existing
stacked-branch and declared revision behavior.

The scalar model should be replaced by a typed DAG only when real work needs
one or more of these tripwires: multiple prerequisites; cross-repository
fan-out or fan-in; artifact-typed edges; revision pinning beyond the existing
stacked-branch mechanism; optional dependencies; or distinct completion gates
per edge. Until then, lists and per-edge syntax are rejected rather than
partially interpreted.

## Evidence and strict reads

`meta.yml` is authoritative. `TaskMeta.read_for_admission` distinguishes an
absent legacy sidecar from unreadable YAML, a non-mapping document, and an
invalid `depends_on`. General display code may still use the tolerant reader,
but admission never does. Metadata mutators refuse to rewrite corrupt input,
so id/display-name backfill cannot erase damaged dependency evidence.

`plan.md` may repeat the assertion in top-level YAML frontmatter:

```yaml
---
depends_on: api:api-task-260716-abcd
---
```

No frontmatter, or frontmatter without `depends_on`, is valid. When present,
the plan value must parse with the same scalar grammar and normalize to exactly
the metadata value. A plan-only assertion, mismatch, or malformed frontmatter
is an admission error. Hive never scans plan prose for prerequisites.

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
auto-repair repository identity.

Each admission invocation snapshots every enrolled project, its tasks, and
its own workflow descriptors. Qualified `[project, slug]` identities and
same-project numeric ids are indexed without using the global task resolver.
Duplicate or ambiguous identities fail closed. Full-chain walking follows
only explicit project edges, detects missing tasks, self-reference, corrupt
upstream nodes, and cycles, and reports a cycle as an ordered qualified path
including the repeated closing node.

## Gate and three verdicts

The depending project's `dependency_gate_stage` is authoritative. It defaults
to `8-finalize`; `9-done` is the only other supported value. The prerequisite's
own workflow must contain both its current stage and a reachable gate.

Admission returns exactly one verdict:

| Verdict | Meaning | Status shape |
|---|---|---|
| Clear | no dependency, or a valid prerequisite at/after the gate | `blocked: false`, wait fields null, `admission_error: null` |
| Wait | valid prerequisite below the gate | `blocked: true`, `blocked_by` and `dependency_stage` populated, `admission_error: null` |
| Admission error | invalid, inconsistent, or indeterminate evidence | `blocked: true`, wait fields null, action `admission_error`, no suggested command, structured `admission_error` |

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
metadata reads.

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

A valid same-project dependency continues to supply the prerequisite slug to
`DependencySnapshot.stacked_base`. Execute resolves the base from the remote
branch, then local branch, then default branch under the existing placeholder
preservation rules. Open-PR uses the prerequisite base only while that remote
branch exists. Explicit cross-project edges always return no stacked base.

## Recovery

Inspect `hive status --json` or the TUI's admission text, then repair the named
`meta.yml`, `plan.md`, project enrollment, remote, workflow, or gate. Do not
delete dependency metadata merely to clear the row unless removing the edge is
the intended model change. For corrupt state that must move out of a forward
stage, use a backward `hive approve --to ...`; forward run/approval resumes only
after admission becomes clear.

## Tests

- `test/unit/dependencies_test.rb`, `task_meta_test.rb`, and
  `plan_frontmatter_test.rb` pin the declaration grammar and strict evidence.
- `test/unit/dependency_admission_test.rb`, `dependency_snapshot_test.rb`, and
  `repository_identity_test.rb` pin graph, gate, workflow, and remote identity.
- `test/integration/dependency_admission_test.rb` reproduces anonymized
  plan-only ordering and cross-project repository-mismatch failures across
  status and manual boundaries.
- status/TUI, daemon, command, and schema suites pin the same three verdicts at
  every consumer.

## Backlinks

- [[modules/task]] · [[commands/status]] · [[modules/daemon]]
- [[commands/run]] · [[commands/approve]] · [[commands/new]] · [[stages/plan]]
- [[modules/worktree]] · [[stages/execute]] · [[stages/open-pr]]
