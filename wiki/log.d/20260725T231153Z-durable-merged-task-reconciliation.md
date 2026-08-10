## Durable merged-task reconciliation

- Replaced the in-memory finalize-only merge watcher and its fixed failure
  drop with a project-local `hive-pr-merge-reconciliation.v1` ledger.
  Candidates bind the exact task generation, repository, PR, observed head,
  remote facts, architecture receipt, archive receipt, hold, retry time, and
  uncapped failure count.
- The daemon now observes PR-bearing coding tasks in stages 5 through 8 before
  automatic recovery and advances one fair candidate per project. Dependency
  and admission holds stay durable but ineligible; open, closed-unmerged,
  unsafe, and failing work remains visible instead of being forgotten.
- GitHub merge facts and architecture-intake acceptance are checkpointed
  before the next external side effect. Restart replay therefore skips
  already accepted phases and uses the same evidence-bound closure transition
  for fresh and backlog work.
- Added a private daemon closure channel restricted to the task's own verified
  same-repository merged PR. It cannot be called through public confirmation,
  cannot take over an operator receipt, and retains the task-local receipt
  after the centralized move to `9-done`.
- Removed the special `--recover-merged-error-reason` dispatch path, fixed
  watcher event enum, constructor compatibility, and patrol-backoff coupling.
  Corrupt or identity-drifted reconciliation bytes are preserved under the
  project daemon quarantine and block only that registration.
- Automatic closure requires an immutable task-head binding. New open-PR state
  records the controller-observed `head_oid`; older task metadata may recover
  it only through a strictly owned registered task worktree. Missing bindings
  remain durably `ambiguous`, head or PR binding drift is held, and
  cross-repository/invalid PR observations remain visible instead of being
  silently discarded.
- The signed closure evidence retains both PR head and merge OIDs. The
  closure service compares both with the reconciler's checkpoint immediately
  before receipt creation, closing the architecture-intake race window.
- Final archive approval now repeats the task-generation, repository,
  GitHub-evidence, daemon PR-binding, durable-attempt, and owned-worktree
  checks while holding the task lock. A verified same-repository PR head may
  satisfy the clean-worktree ancestry guard, but uncommitted or differently
  headed work still blocks.
- Reconciliation records one durable outcome for every scanned coding task,
  including rejected/no-PR rows and zero-row healthy projects. Corrupt input
  is content-addressed in quarantine, terminal candidates compact after the
  retention window, and unresolved/merged/ambiguous candidates fence the
  universal healer so delivery reconciliation cannot race a provider retry.
- Consolidated pull-request URL parsing and controller-observed
  `pr_url`/number/head persistence under `Hive::Gh`; OpenPr and Finalize both
  atomically bind the same canonical identity and propagate bounded GitHub
  timeouts through nested closure probes.
- The operator closure flow now has a real Telegram producer:
  `/close <id|slug> ...` creates a bounded **Verify evidence** callback, then
  the existing allowlisted confirm callback performs the separate archive
  step. JSON CLI closure remains a read-only preview, while interactive CLI
  and web retain explicit confirmation.
- Completed the pre-1.0 one-off wire migration: only `hive-status.v7`,
  `hive-operational-status.v3`, and `hive-act.v2` remain. Superseded schemas
  and compatibility assertions were removed so recovery is represented by
  one current contract rather than another legacy branch.
- Documented the three closure-evidence `gh api` calls as Brakeman false
  positives: every dynamic value passes the strict repository, host, commit,
  or branch validator before `Hive::Gh.capture3` gives discrete arguments to
  `Process.spawn`, so no shell interprets an endpoint.
