---
title: hive stack
type: command
source: lib/hive/commands/stack.rb, lib/hive/dependency_snapshot.rb, schemas/hive-stack.v1.json
created: 2026-11-22
updated: 2026-11-22
tags: [command, dependencies, stacking, admission, json]
---

**TLDR**: `hive stack TARGET --on PREREQUISITE [--on ...]` sets, and
`hive stack TARGET --clear` removes, an existing task's `depends_on`
declaration at any unfinished stage. It is the post-creation counterpart of
`hive new --depends-on` ([[commands/new]]): same grammar, same `meta.yml`
field, same admission model ([[modules/task_dependencies]]). The change gates
scheduling immediately; it never rebases an existing worktree branch.

## Usage

```
hive stack TARGET --on PREREQUISITE              # one prerequisite: stacked, project gate
hive stack TARGET --on A --on B                  # list: scheduling-only, every edge at 9-done
hive stack TARGET --on other-project:slug        # explicit cross-project edge, scheduling-only
hive stack TARGET --clear                        # remove the dependency
hive stack TARGET --on PREREQUISITE --project P  # scope TARGET lookup to one project
hive stack TARGET --on PREREQUISITE --json       # hive-stack.v1 document on stdout
```

TARGET resolves like other task commands (path, slug, or numeric id through
`Hive::TaskResolver`). Options: `--on` (repeatable, a task id, slug, or
`project:slug`), `--clear`, `--project NAME`, and the global `--json`.
Exactly one of `--on` or `--clear` is required.

## Examples

```
hive stack 1702 --on 1695
hive stack wire-up-export-260618-ab12 --on api:add-export-endpoint-260618-ab12
hive stack release-export --on api-task --on ui-task
hive stack 1702 --clear --json
```

## Behavior

1. `hive stack` parses `--on` through `Hive::Dependencies.normalize_declaration`,
   so one occurrence is a scalar and repeated occurrences are a list, exactly
   as in `hive new`.
2. Resolve TARGET. A task in its workflow's terminal stage (for `coding`,
   `9-done`) is refused: a finished task has nothing left to gate.
3. Refuse a dependency on a draft-PR workflow, which does not support
   stacking (`--clear` is still allowed).
4. Observe the task, take the project commit lock, then the task lease,
   re-checking task identity at each step. A live stage agent owns the lease,
   so the command fails with the retryable `ConcurrentRunError` (exit 75)
   instead of editing metadata under a running stage.
5. Under the lease, refuse when TARGET's own `plan.md` frontmatter declares a
   `depends_on` that differs from the request (or when `--clear` would leave
   a plan-only assertion). Writing it anyway would park the task on
   `plan_dependency_mismatch` / `plan_dependency_missing`. Setting the value
   the plan declares is allowed, and is how to repair an existing mismatch.
   `plan.md` itself is never edited, because its bytes are the reviewed
   plan-review artifact.
6. Compute the admission verdict TARGET would have with the new declaration
   (`DependencySnapshot.proposed_dependency_verdict`, which replaces the
   task's snapshot in place in a targeted admission context). An unchanged
   declaration writes nothing. A cycle or self-reference is refused. Any
   other admission error, such as a missing prerequisite, is written anyway
   and reported as a note, matching creation's
   "unresolved future dependencies stay captureable" rule.
7. Rewrite `meta.yml` through `TaskMeta.rewrite` under the observation and
   record one `hive/state` commit: `hive: <stage>/<slug> stacked on <ref>`,
   `depends on <a>, <b>`, or `unstacked`. If the commit fails, the previous
   `meta.yml` bytes are restored before the error propagates.

### Effects on a task that already has a worktree

Execute reads the stacked base only when it creates the worktree, and
auto-rebase always targets `origin/<default>`. So for a task past execute
entry, the declaration `hive stack` writes gates scheduling (status, daemon, `hive run`,
forward `hive approve`) but does not move the code on the branch. The command
says so in a note naming the recorded `base_ref`. Open-PR still derives its
PR base from the declaration (the prerequisite's branch while it exists on
origin), so rebase the task branch onto the prerequisite yourself if the work
must build on that code.

## Output

Text mode prints one headline (`<slug> now stacked on <ref>`, `now depends
on <a>, <b>`, `no longer depends on another task`, or `... nothing changed`),
one `waiting for <prereq> (<stage>) to reach <gate>` line per unmet
prerequisite, and `hive: note:` lines on stderr for list/cross-project
policy, an existing worktree, or an admission hold.

## JSON contract (`schema = "hive-stack"`, version 1)

```json
{
  "schema": "hive-stack",
  "schema_version": 1,
  "ok": true,
  "project": "hive",
  "slug": "dependent-task",
  "id": 1702,
  "stage": "3-plan",
  "depends_on": "base-task",
  "previous_depends_on": null,
  "changed": true,
  "committed": true,
  "dependency": {
    "state": "wait",
    "unmet_dependencies": [
      {"reference": "base-task", "blocked_by": "base-task",
       "dependency_stage": "4-execute", "required_gate": "8-finalize"}
    ],
    "admission_error": null
  },
  "notes": []
}
```

`dependency.state` is `clear`, `wait`, or `admission_error`, matching what
status and the daemon report for the new declaration. `admission_error.reason_code`
is a `Hive::DependencyAdmission::REASON_CODES` value, deliberately left
unenumerated in this schema. External consumers validate against
`schemas/hive-stack.v1.json` via `Hive::Schemas.schema_path("hive-stack")`.

## Errors and exit codes

Failures emit the `hive-stack` error envelope under `--json`; `error_kind` is
closed and mirrors `Hive::Schemas::StackErrorKind::ALL`.

| `error_kind` | Exit | Cause |
|---|---|---|
| `usage` | 64 | malformed argv, or neither/both of `--on` and `--clear` |
| `invalid_task_path` / `ambiguous_slug` | 64 | TARGET did not resolve to exactly one task |
| `invalid_dependency` | 64 | a reference failed the `depends_on` grammar |
| `dependency_cycle` | 64 | the edge would close a cycle or point at TARGET itself |
| `unsupported_workflow` | 64 | draft-PR workflows do not support dependency stacking |
| `wrong_stage` | 4 | TARGET is in its workflow's terminal stage (`current_stage` set) |
| `plan_conflict` | 78 | TARGET's `plan.md` declares a different dependency (`reason_code`, `offending_ref`, `safe_correction` set) |
| `concurrent_run` | 75 | a stage agent or another writer holds the lease or commit lock (`holder`, `lock_path` when known) |
| `stale_task` | 75 | TARGET moved or changed identity mid-update; retry |
| `config` | 78 | invalid `meta.yml` (never rewritten) or missing/duplicate project enrollment |
| `git` | 70 | the `hive/state` commit failed; `meta.yml` was restored |
| `internal` | 70 | uncategorised crash |
| `error` | 1 | any other `Hive::Error` |

Pre-dispatch argv failures use the same envelope with `error_kind: "usage"`
(`Hive::CliUsageContracts.declare("stack", ...)`). If encoding an error
envelope raises `JSON::GeneratorError`, the command warns on stderr, emits no
substitute document, and re-raises the original typed failure (the shared
`EnvelopeEmitter` serialization fallback).

## Tests

- `test/integration/stack_test.rb`: stacking with commit and admission
  read-back, restack and clear, list notes, no-op, post-execute worktree
  note, missing-prerequisite hold, cycle and self-reference refusals,
  plan.md agreement and repair, terminal-stage refusal, usage and grammar
  refusals, live-lease refusal, commit-failure restore, and schema-valid JSON.
- `test/unit/schema_files_test.rb`: closed error-kind mirror, producer-kind
  envelopes, success-payload shape.
- `test/unit/cli_test.rb`, `test/unit/cli_usage_contracts_test.rb`,
  `test/unit/remote/command_policy_test.rb` (`stack` is local-only).

## Backlinks

- [[cli]] · [[commands/new]] · [[modules/task_dependencies]]
- [[commands/approve]] · [[commands/run]] · [[modules/worktree]]
