---
created: 2026-08-25
tags: [log, stage_action, task_closure, guarded_archive, architecture, patrol]
---

# One internal guarded-archive protocol replaces the StageAction closure branch

## What changed

Architecture patrol finding
`pr-1015-8181522c6a7dcff1:remove-closure-specific-branch-from-stage-action`
flagged a bidirectional coupling between the shared verb dispatcher and the
closure subsystem:

1. `Hive::TaskClosure#transition!` delegated archival to the closure-specific
   entrypoint `StageAction.archive_with_closure`.
2. `StageAction#do_call` branched its control flow on closure-specific state
   (`return close_with_receipt(...) if @closure_receipt_digest`).
3. `StageAction` raised `Hive::TaskClosure::InvalidReceipt` directly, giving
   the shared boundary a reverse dependency on the specialized error contract.

The fix defines one internal guarded-archive protocol,
`lib/hive/commands/guarded_archive.rb` (`Hive::Commands::GuardedArchive`):

- The protocol owns guarded retirement mechanics: pre-transition guard check,
  resume-at-terminal versus force-move-and-run, the internal no-rebase run
  policy, and the completion broadcast (terminal stage + `:complete` marker).
- It holds no receipt semantics. The caller injects a `transition_guard`
  callable (rechecked inside the atomic move lock by Approve) and an optional
  `observation_guard`.
- `Hive::TaskClosure#transition!` now drives `GuardedArchive.call` directly and
  owns its own receipt-authority rule ("closure receipts can authorize only the
  archive transition", still `InvalidReceipt`).
- `StageAction` lost `.archive_with_closure`, the `closure_receipt_digest`
  parameter, `close_with_receipt`, and every reference to `TaskClosure`.
  Ordinary archive keeps its terminal-marker and `8-finalize` source rules.

Observable behavior is unchanged: guard ordering (before the move and again
inside the lock), no-rebase Done runs, quarantine/resume semantics, and
completion events are all preserved; existing end-to-end closure tests pass
unmodified in their assertions.

## Tests

- New `test/unit/commands/guarded_archive_test.rb`: noop completion on a
  terminal complete task, markerless resume without rebase or completion
  event, active-stage retirement proving upfront-plus-in-lock guard order and
  observation composition, and a source-level regression guard that
  `StageAction` carries no closure-specific path.
- `test/unit/commands/stage_action_test.rb`: closure entrypoint test replaced
  with a `TaskClosure#transition!` authorization test.
- `test/integration/run_stage_action_test.rb`: evidence-receipt integration
  tests now drive `GuardedArchive` through the production-shaped helper.

## Wiki

- Updated `wiki/commands/stage_action.md` (TLDR, closure section, step 3).
