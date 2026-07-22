# Bound scheduled LLM-wiki refreshes

- Prevented the main, Rails, and E2E test harnesses from installing LLM-wiki systemd units in the developer's real home while creating disposable projects.
- Serialized all scheduled project refreshes through one non-blocking user-runtime lock, randomized timer starts, and capped each service at 4 GiB with swap disabled.
- Routed commit-triggered Hive refreshes through the same memory-bounded systemd service; unavailable user managers remove the unusable dispatch marker and fall back to machine-wide admission across repositories.
- Added bounded multi-batch draining for commits arriving while a oneshot is active, plus a Ruby-native OS lock keeper when the `flock` executable is unavailable.
- Isolated the portable Ruby lock keeper from inherited Bundler and coverage loader variables so a hook cannot mistake an incompatible system Ruby startup failure for a busy global lock.
- Deployed the packaged refresh runner in each repository's shared Git directory and added an executable-runner condition so protected checkouts stay clean and units for removed projects are skipped without launching a process.
- Canonicalized linked worktrees to one primary-checkout timer per repository.
- Added first-command migration that stops rewritten services, retries interrupted stops, preserves disabled schedules, removes only marked/config-confirmed/test Hive debris (including exact `/tmp/e2e-runs?<date>-<pid>-<suffix>` and marked timer-only debris), collapses legacy linked-worktree units onto the primary checkout, and durably retries failed systemd reloads without breaking init.
- Published generated wiki commits to `llm-wiki/refresh` with fetched/merged remote history; push failures retain the generated commit and queue without opening the provider circuit or mutating protected `main`.
- Added freshly fetched default-branch integration, crash-safe remote receipt reachability even after remote rewind/deletion, partitioned retained-commit publication, no-diff acknowledgement commits, and a durable publication-conflict marker that suppresses automatic retries until explicit recovery.
- Added regression coverage for generated units, stale-unit migration and ownership, disabled schedules, systemctl failure recovery, publication retry/conflicts, and the Rails/E2E environment isolation contracts.
