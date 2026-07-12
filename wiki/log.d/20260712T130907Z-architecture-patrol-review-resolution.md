# 2026-07-12 — Architecture patrol review resolution

- Narrowed architecture boundaries: `Hive::Gh` remains shared GitHub/git
  transport while `Hive::RefactorPatrol::GithubGateway` owns patrol-specific
  issue, merged-PR, and publication-proof protocol. `JobStore` remains the sole
  lock/read/write facade while record validation, claim transitions, and
  rebuildable index projection live in dedicated collaborators. Issue inventory
  validates real REST pull-request rows against `/pull/N` identity before
  excluding them, while issue rows retain strict `/issues/N` validation.
- Made merged-PR catch-up incremental and restart-safe without changing the
  authoritative `reconciler.json` v2 checkpoint. An identity- and
  checkpoint-fingerprint-bound progress sidecar persists page/intake cursors
  and jittered exponential backoff; monotonic tick/per-call budgets plus fair
  project rotation prevent a slow GitHub repository from stalling the daemon.
  Each scan freezes both its merge-time upper bound and first-page result count,
  uses stable creation ordering, and restarts page traversal without moving that
  bound if GitHub indexing changes the count or terminal size. Strict persisted
  cursor/scalar/timestamp/OID validation quarantines impossible continuation
  state before another GitHub call.
  Catch-up, bounded finalize-watcher state polling, and immediate watcher
  hydration—including origin identity discovery—share that absolute budget, so
  a batch of merged PRs cannot each claim a fresh remote timeout; deadline
  deferral preserves the watcher entry
  without consuming its failure budget, while a hung `gh pr view` is terminated
  and enters ordinary watcher backoff instead of pinning the dispatcher.
  Durable retry `not_before` is anchored at observed failure time using
  monotonic elapsed time, and consecutive watcher-intake failures no longer get
  reset merely because the preceding PR-state poll succeeded.
- Scoped PR publication recovery to validated patch generations. Append-only
  publication attempts bind base/commit identity and immutable push/create
  phases, reconcile a landed push before drift supersession, recheck trunk
  immediately before creation intent, reject a missing completed remote, and
  allow branch replacement only under an exact lease for the previously pushed
  OID. Legacy flat replacement proof remains usable after additive namespaced
  migration, and phase evidence remains part of unique continuation ownership
  across restarts or consent changes.
- Added explicit fresh-init `--refactor-patrol` / `--no-refactor-patrol`
  selectors before any state write while retaining default-enabled discovery
  and separate default-off auto-fix/issue gates. Existing-project re-init paths
  reject those fresh-only selectors instead of silently ignoring them. Added non-mutating
  `hive refactor-patrol PROJECT --list|--show JOB_ID [--json]` inspection with
  the versioned `hive-refactor-patrol-jobs.v1` contract. List pages now use an
  explicit 1..100 bound plus an immutable sequence/high-water cursor and read
  only selected full jobs instead of the permanent ledger. Writer registration
  now reserves immutable membership before the authoritative job write and
  publishes only a contiguous durable prefix; exact crash retries recover
  unpublished membership, pre-index jobs migrate on the next authoritative
  write, and explicit rebuilds scan under the writer lock before atomically
  swapping a fully prepared generation. Show retry/publication
  histories use the same default bound unless `--full` is requested, and invalid
  show ids or selector-less query modifiers remain usage errors without masking
  corruption in valid-id records. Legacy flat patch history now reports honest
  truncation metadata, while new action blocks snapshot claim generations so
  same-second writes or clock rollback cannot hide a live blocker. Superseded
  retry failures no longer appear as current blockers after a job succeeds.
- Retained the other review hardening: verified Claude safe mode for read-only
  discovery, root-confined bounded source reads at the outer mapper boundary
  before package, Python-route, or documentation paths reach a reviewer,
  the same 256 KiB bound for cited evidence verification,
  mode-correct v1/v2 CLI errors,
  non-draft PR reconciliation, later-stage handoff-proof recovery, tick-scoped
  candidate ownership snapshots with fresh effect fences, and shared atomic
  directory-fsync behavior.
- Hardened the shared GitHub timeout itself: captures now own a process group
  and include pipe drain in the deadline, so a TERM-resistant helper that
  inherits stdout after `gh` exits is killed instead of hanging the daemon.
  Push/ref lookup now also rejects unsafe branch and option-shaped remote
  targets. The progress store uses JSON rather than `Marshal` for detached
  dry-run state, and narrowly documented argv-form Git calls remain explicit
  Brakeman false positives rather than security warnings.
- Expanded focused unit, integration, schema, and command validation, including
  a real-git/bare-remote regression whose forked worker is hard-killed after
  push but before completion persistence, followed by dead-claim recovery,
  durable supersession, exact old-OID replacement, one verified PR, and one
  mandatory review handoff. Refreshed CLI, command, GitHub, daemon,
  state-model, testing, and public documentation for the resolved contracts.
