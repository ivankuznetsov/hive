## daemon — self-heal non-token error classes + close the web/ auto-commit scope gap

**Action:** Broadened the daemon's `StaleAgentHealer` so red tasks whose error
is operational (not a usage/credit limit) auto-retry and advance instead of
parking for a human, and fixed the hive-code bug that made web-UI tasks brick.

**Healer (`lib/hive/daemon/stale_agent_healer.rb`):** under the existing
bounded per-process retry budget (default 3, then park), now auto-recoverable:
- `ERROR reason=ensure_clean_on_exit_failed` (any worktree-owning stage). The
  rerun re-runs CleanExit, which re-adds and re-scope-checks the residue — it
  never bypasses the check, so genuinely out-of-scope residue re-fails and
  parks. Root cause of the common trigger (dry-run skip-log residue) was fixed
  in PR #519; this stops the immediate manual park.
- `REVIEW_ERROR phase=reviewers reason=all_failed` (every reviewer crashed for
  a non-limit reason, e.g. a native reviewer exited non-zero).
- `REVIEW_ERROR phase=fix` auto-commit failures: `fix_auto_commit_scope_failed`,
  `fix_auto_commit_sign_policy_failed`, `fix_auto_commit_signing_failed`.

Token/budget carve-out preserved: a total reviewer usage-limit still sets
`reason=limits_reached` (not `all_failed`) and stays on the `retry_after`
cooldown path. Integrity/operator reasons stay manual: `fix_status_check_failed`,
`fix_tampered`, `dirty_worktree`, `execute_stale`.

**Config (`lib/hive/config.rb`):** added nested `web/` source globs
(`web/app/**`, `web/lib/**`, `web/src/**`, `web/test/**`, `web/tests/**`,
`web/spec/**`, `web/docs/**`) to the auto-commit `allowed_paths` DEFAULTS, so a
fix touching a monorepo Rails/JS app under `web/` auto-commits. Sensitive nested
dirs (`web/config`, `web/bin`, `web/db`) are intentionally NOT allowlisted, so
they stay out of scope exactly like their top-level counterparts (denied wins
over allowed). This unbricks the `web/app/**` / `web/test/**` scope violations
(task #1361 class).

**Bot/TUI:** unchanged — `ensure_clean_on_exit_failed` stays in
`ERROR_MANUAL_ONLY_REASONS` as the post-exhaustion "inspect manually" backstop;
the daemon retries first, a human sees it only after the budget is spent.

**Tests:** healer auto-recovers all three new classes (incl. bounded-then-park);
`dirty_worktree` / `fix_status_check_failed` stay manual; CleanExit auto-commits
`web/app`+`web/test` residue but flags `web/config` as a scope violation.

This is project-agnostic (healer) and global-default (config), so it applies to
every daemon-managed project, not just hive.
