## babysitter — gitignore dry-run worktree artifacts so CleanExit stays clean

**Action:** Fixed the recurring red-task cluster where patrol/babysit dry-run
runs left `.babysitter-dry-run-skipped.log` (and the `.hive-babysitter-dry-run-bin/`
overlay shims) at the worktree root. `Hive::Stages::CleanExit.run!` on stage exit
runs `git add -A` and the `review.fix.auto_commit.scope_check` rejected those
untracked artifacts as out-of-scope residue, landing tasks as
`:error reason=ensure_clean_on_exit_failed` (and `review_error
reason=fix_auto_commit_scope_failed`).

**Fix:**
- `.gitignore`: ignore `.babysitter-dry-run-skipped.log`,
  `.babysitter-dry-run-plan.md`, and `.hive-babysitter-dry-run-bin/` — these are
  transient dry-run artifacts that must never be committed, so `git add -A` /
  `git status --porcelain` skip them and CleanExit exits `:clean`.
- `lib/hive/babysitter/dry_run_env.rb`: extracted `OVERLAY_DIRNAME` /
  `SKIP_LOG_BASENAME` constants and `rm_rf`'d the overlay-bin dir in the
  `with_env` `ensure` block (pure tooling, nobody reads it after the block). The
  skip log is deliberately kept — it is the dry-run diagnostic record that
  callers/tests read after `with_env` returns.

**Tests:**
- `test/unit/stages/clean_exit_test.rb`: gitignored dry-run residue exits `:clean`.
- `test/unit/babysitter/dry_run_env_test.rb`: `with_env` removes the overlay dir
  on exit while keeping the skip log; real repo `.gitignore` ignores all three
  artifacts (`git check-ignore`).

Not addressed (separate causes seen in the same red sweep): `web/app/**` /
`web/test/**` falling outside the auto-commit `allowed_paths` (#1361),
reviewers `all_failed` (#1378), and review `wall_clock` timeouts (writero #1).
