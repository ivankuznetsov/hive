# 2026-11-28 — Internal PR checkout reconciliation and generation-scoped review state

**Action:** Implemented the single durable checkout reconciliation authority for
`source: ad-hoc` internal PR review tasks across `lib/hive/internal_pr_checkout/`
and wired it through ad-hoc creation, durable attempt admission, human/daemon/recovery
adapters, review execution, custody enforcement, status/closure/watcher readers,
and end-to-end bare-remote integration tests:

- **Authority & store (`lib/hive/internal_pr_checkout/`):** Added strict identity
  derivation (`Identity`), closed typed outcomes (`Result` — `not_applicable`,
  `current`, `reopened`, `busy`, `blocked`), durable controller store (`Store` —
  `current.json`, `pending.json`, `candidate.json`, `history-root.json`,
  `grant-index.json`, chained manifests), safe `AgentGitGate` transition/rollback
  (`GitTransition` — quarantine fetch, no-overwrite-ignore protection, immutable
  candidate archive refs), and `Reconciler` with shared `PassArchive` ordinals
  and atomic logical publication at final provider confirmation.
- **Creation & admission (`AdhocReview`, `Attempts::Dispatcher`, `Generation`, `Context`):**
  Coordinated creation under the project commit lock with canonical `head_oid`
  and generation 1 initialization while delegating reuse to U2; added owner-first
  attachment, conditional SQLite lease claim (`claim_if`) released before launch
  handoff, legacy implicit gen-1 token compatibility, and locked worker
  `:local_verify` checks.
- **Adapters & schemas (`CommandDispatch`, `Run`, `StageAction`, `Daemon::Dispatcher`, `RecoveryCoordinator`):**
  Wired explicit reopen vs. local verify, single monotonic network deadlines and
  daemon retry backoff pacing, single foreground JSON/text reconciliation
  emission (`schemas/hive-run.v2.json`, `schemas/hive-stage-action.v2.json`,
  `schemas/hive-status.v9.json`), internal `RemoteCi` `base_conflict` guidance,
  and ordinary adoption guards.
- **Generation-scoped review & readers:** Enforced `MANUAL_STEERING` hold and
  coherent `read_only_snapshot` bracketing across `Review`, `TaskAction`,
  `Commands::Status`, `StatusConsumer`, `TaskClosure`, and `PrMergeWatcher`;
  scoped `PullRequestOutcome.latest_for_generation`; kept internal PR publication
  strictly local-only (`GithubPublisher`, `Review::Publication`); and enforced
  constant-anchor custody at every reviewer (`Reviewers::Agent`,
  `Reviewers::Runtime.capture`), fix, triage, CI-fix, and `BrowserTest.run_attempt`
  spawn boundary.
- **Documentation & tests:** Replaced the pinned-reuse integration test with
  real-bare-remote AE1–AE9 acceptance coverage in `test/integration/adhoc_review_test.rb`
  and `test/integration/run_review_test.rb`, and updated [[stages/review]],
  [[modules/worktree]], [[modules/attempts]], [[modules/protected_files]],
  [[state-model]], and [[publication-recovery]].
