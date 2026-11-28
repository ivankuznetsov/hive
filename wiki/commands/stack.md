---
title: hive stack
type: command
source: lib/hive/commands/stack.rb, lib/hive/dependency_snapshot.rb, schemas/hive-stack.v1.json
created: 2026-11-22
updated: 2026-11-22
tags: [command, dependencies, stacking, admission, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-stack) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive stack TARGET --on PREREQUISITE [--on ...]` sets, and
`hive stack TARGET --clear` removes, an existing task's `depends_on`
declaration at any unfinished stage. It is the post-creation counterpart of
`hive new --depends-on` ([[commands/new]]): same grammar, same `meta.yml`
field, same admission model ([[modules/task_dependencies]]). The change gates
scheduling immediately; it never rebases an existing worktree branch.

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
