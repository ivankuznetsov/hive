## 2026-08-15 — Plan review default-injection and deny-path coverage

Three plan-review files carried uncovered lines that were all *default*
collaborators — the seam a test never takes because every test injects a
double:

- `Automation.run!` falls back to `Orchestrator.run!` when no `orchestrator:`
  is passed. Every existing test injected one, so the real dispatch was cold.
  Covered by replacing the `Orchestrator.run!` singleton instead of injecting.
- `Commands::PlanReviewRun` builds a default resolver and a default committer
  in `initialize`. The resolver's plan-stage scoping
  (`TransitionGuard::PLAN_STAGE`) and `commit!`'s
  `Lock.with_commit_lock` + `GitOps#hive_commit` body are now exercised.
- `ApprovalPolicy` has two deny-by-rescue paths: a non-integer
  `policy_version:` filter raises `ArgumentError` out of `Integer()` in
  `match`, and a policy missing `valid_from` raises `KeyError` inside
  `applicable?`. Both must return "no match" rather than propagate.

Note for future coverage work in this repo: `approval_policy_test.rb` keeps
its fixtures under a `private` marker at the bottom of the class. Test methods
appended after that marker are private, and Minitest silently does not collect
them — the run reports fewer cases without failing. Add new tests *above*
`private`.

See [[modules/plan_review]] and [[testing]].
