# Keep scheduled wiki refreshes out of user checkouts

- Replaced Hive's scheduled direct-Codex wiki writer with a thin managed
  wrapper that delegates `--project <root> --drain` to the canonical shared
  Git runner, with a safe project-local fallback. Delegation requires an
  explicit drain-capability marker and fails closed for legacy runners.
- Scheduled and post-commit refreshes now share the same queue, lock, circuit,
  subscription limits, disposable worktree, and `llm-wiki/refresh` branch.
  Empty scheduled drains do not launch a provider.
- Hive bootstrap now installs the validated config and canonical executable
  runners under the absolute Git common directory. The common post-commit
  hook resolves the committing worktree at runtime, prefers that shared
  runner, and passes its exact root with `--project`, so linked worktrees do
  not depend on stale checkout-local scripts.
- Fresh-init rollback now snapshots that common hook and managed shared
  runtime. A late failure restores existing bytes and modes without removing
  unrelated queue state, or removes the whole shared runtime when init created
  it, including when the target checkout is a linked worktree with a `.git`
  file.
- Added subprocess coverage proving the wrapper preserves dirty tracked and
  untracked primary-checkout work, never launches Codex itself, prefers the
  shared runner, and falls back locally when shared state is unavailable.
- Documented GNU `timeout`/`gtimeout` as the required bounded-execution
  dependency. Missing coreutils now has explicit fail-closed guidance rather
  than suggesting an unbounded provider or Git fallback.
- Documented the shared-Git-dir queue, failed-source, breaker, and log paths;
  the 25-source automatic backlog limit; 10-source batch default; pin,
  deferred-work, quarantine, and repeated-failure breaker cases; and the
  explicit subscription-backed `--retry-failed <sha|all>` recovery loop.
