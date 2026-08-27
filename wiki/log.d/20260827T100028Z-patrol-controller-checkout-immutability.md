---
date: 2026-08-27
slug: patrol-controller-checkout-immutability
pages: [commands/run, commands/rebase-status, modules/rebase, modules/patrol, modules/agent_git_gate, testing, gaps]
---

Controller workflows now skip generic `hive run` auto-rebase before stage or
worktree-derived behavior can activate it. The closed JSON reason is
`controller_workflow`; the current run schema also accepts the existing
`managed_draft_pr_handoff` exclusion.

The read-only `hive rebase-status` inspector now mirrors both exclusions, so it
cannot recommend an auto-rebase that `hive run` will skip.

Patrol Fix Validate now preflights the authoritative fix checkout at its
receipt-bound HEAD, materializes that exact commit into a private detached
checkout, runs validation there, and force-discards the registered disposable
tree on success or exception. Formatters and tests can no longer dirty the
authoritative patch checkout through Hive's working directory. The post-run
HEAD and byte checks remain in place to detect external same-user mutation and
fail without appending a validation receipt.

Checkout and temporary-root cleanup are recovery-only: a cleanup failure warns
with the retained checkout path but cannot replace an in-flight validator or
materialization error, or discard a completed validation result before its
receipt is appended.

The disposable checkout contains only tracked files from the receipt-bound
commit. Hive does not copy or link ignored dependencies, caches, tools, or
secrets from the authoritative checkout. Operator-configured and agent-selected
commands must include any required bootstrap inline; the Fix prompt now states
that contract before the agent selects validation commands.

`Hive::AgentGitGate.remove_materialization` gained a strict opt-in force flag
for Hive-owned disposable trees while retaining root confinement and exact
repository-registration proof. Focused real-repository tests cover dirty
discard, exact detached validation, exception cleanup, materialization failure,
external mutation detection, non-masking checkout/root cleanup failures, and
the controller rebase guard. The Patrol reviewer suite now resets cooperative
shutdown state per test so an earlier signal-handling fixture cannot suppress
all reviewer launches under a different randomized full-suite order. No index
update was needed because no wiki page was added.
