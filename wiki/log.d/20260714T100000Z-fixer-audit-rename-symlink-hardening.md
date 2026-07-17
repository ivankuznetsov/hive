# 2026-07-14 — Refactor patrol fixer audit rename/symlink hardening

- All fixer audit diffs (`--name-only`, `--numstat`, `--unified=0`, trunk
  drift) now pass `--no-renames`, so a staged rename surfaces both endpoints
  and can no longer bypass the boundary, public-contract, or diff-size guards.
- The audit rejects any changed path that is (or crosses) a symlink inside the
  worktree with the new terminal `symlinked_path` outcome, which is also
  issue-eligible as a deterministic nonfixable reason.
- The public-contract guard now verifies the base commit with `git cat-file -e`
  before treating a failed `git show` as a new file; any other git failure
  re-raises instead of letting a deleted public declaration pass unaudited.
- `Hive::ConfigError`/`ArgumentError` in `Fixer#attempt` produce a terminal
  `fix_error`, and ActionRunner persists non-terminal fix error details as
  write-once `fix_release_<generation>` receipts instead of dropping them.
