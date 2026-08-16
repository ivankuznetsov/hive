# 2026-08-16 — isolate Patrol completion recovery from daemon child reaping

**Action:** Kept ordinary Patrol's fail-closed occurrence finalization while
isolating scheduler completion errors at the daemon child-reaping boundary. A
failed worker with a prepared or dispatch-uncertain effect now leaves the exact
occurrence reserved for recovery and emits a project-scoped fatal diagnostic;
it no longer exits the daemon and interrupts unrelated workers. Added a focused
dispatcher regression for the live `patrol occurrence has nonterminal effects`
failure.

**Tests:** `test/unit/daemon/dispatcher_test.rb -n /patrol_completion/` (2 runs,
5 assertions); `test/unit/daemon/patrol_scheduler_test.rb` (31 runs, 184
assertions); RuboCop on the changed Ruby files; `git diff --check`.
