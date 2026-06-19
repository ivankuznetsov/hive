---
title: Hive::Gh
type: module
source: lib/hive/gh.rb
created: 2026-06-08
updated: 2026-06-19
tags: [github, gh, module, pr]
---

**TLDR**: `Hive::Gh` is the shared GitHub CLI / git network helper for PR publication, finalization, review mirroring, and babysitter context. It wraps `gh`/`git` subprocesses with non-interactive environment defaults, a bounded network timeout, typed return structs, and fail-loud JSON parsing so callers do not confuse a remote outage with a clean PR state.

## API Map

| API | Purpose |
|-----|---------|
| `ensure_authenticated!(cfg = nil)` | Runs `gh auth status`; raises `Hive::GhError` when GitHub auth is missing. Used by [[stages/open-pr]] and [[stages/finalize]]. |
| `push_branch(worktree_path, branch, cfg: nil)` | Runs `git push -u origin <branch>` and returns `PushResult(success:, stdout:, stderr:)`; finalize uses this non-bang path so persistent push failure can become `ERROR reason=unpushed_commits`. |
| `push_branch!(worktree_path, branch, cfg: nil)` | Hard-fail wrapper around `push_branch`; open-pr uses it because it has no marker-level push recovery path. |
| `lookup_prs_for_branch(worktree_path, branch, cfg: nil)` | Runs `gh pr list --head <branch> --state all --json ...` from the worktree cwd. Fail-loud on CLI or JSON shape errors. |
| `lookup_existing_pr(...)` | Returns only `OPEN` PRs from `lookup_prs_for_branch`; closed/merged PRs are excluded from the normal open-pr path. |
| `lookup_merged_pr(..., head_oid: nil)` | Returns a `MERGED` PR, optionally requiring `headRefOid` to match the current local `HEAD`. [[stages/open-pr]] uses this for already-merged branch recovery. |
| `pr_state(pr_url, cfg: nil)` | Runs `gh pr view <url> --json state` and returns the state string. `Hive::Commands::StageAction` uses it to re-confirm a daemon-only merged-finalize-error archive recovery before moving the task to `9-done`. |
| `list_open_prs(worktree_path, cfg: nil)` | Runs `gh pr list --state open --limit 1000` and includes `mergeStateStatus`; [[modules/babysitter]] uses that field to prioritize dirty/conflicted PRs before age. |
| `pr_status_rollup` / `pr_failing_job_logs` | Fetch PR merge/check state and tail-clipped failing job logs for babysitter repair context. |
| `pr_diff_stat` / `pr_base_divergence` | Fetch base and compute diff/divergence context for babysitter prompts. `pr_base_divergence` is best-effort and returns blank fields on git hiccups. |
| `pr_stats(pr_url, cfg:)` | Fetch a PR's `additions`/`deletions`/commit count via `gh pr view <url> --json additions,deletions,commits` (keyed off the URL, no worktree/chdir needed) for the [[modules/digest]] footer. Returns `{additions:, deletions:, commits:}` (commits as a count); raises `Hive::GhError` on a failed/unparseable lookup so the caller can drop just that PR. |
| `pr_frontmatter(path)` | Safe YAML frontmatter reader for `pr.md`; malformed YAML warns and returns `{}`. |
| `scan_pr_for_secrets(state_file:, pr_url:, cfg: nil)` | Scans local state-file text plus remote PR body for `Hive::SecretPatterns`; returns `ScanResult` with `fetch_failed` instead of silently treating remote fetch errors as clean. |
| `capture3(*cmd, chdir: nil, cfg: nil, timeout_sec: nil)` | Shared subprocess wrapper used by the helpers above. |

## Subprocess Contract

`capture3` uses `Process.spawn` with argv-form commands, never shell interpolation. It sets `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` so unattended daemon/babysitter paths fail instead of blocking on terminal prompts. The timeout comes from `cfg["gh"]["network_timeout_sec"]` when present and positive, otherwise defaults to `NETWORK_TIMEOUT_SEC = 60`. Timeout handling sends TERM, waits briefly, then sends KILL.

`gh` does not support `-C`, so PR CLI calls that depend on repository context use `chdir: worktree_path`. Git commands still pass explicit worktree arguments where the command supports them.

## Recovery Boundaries

Normal workflow commands do not treat a PR URL as sufficient proof that a task can advance. `lookup_existing_pr` intentionally ignores closed and merged PRs; `scan_pr_for_secrets` fails loud when the remote PR body cannot be fetched; and `pr_state` re-checks GitHub state immediately before the internal `hive archive --recover-merged-error-reason` path accepts an `8-finalize` `ERROR` marker. That recovery path also requires the current marker's `reason=` to exactly match the daemon-provided flag, so a stale merge-watch entry cannot advance a newer error.

## Tests

- `test/unit/gh_test.rb` covers frontmatter parsing, secret-scan fetch-failure semantics, open/merged PR lookup contracts, `pr_state` success/error parsing, `PushResult`, subprocess timeout/termination, `list_open_prs` JSON fields, failing-job log clipping, and malformed JSON failures.
- `test/unit/daemon/pr_merge_watcher_test.rb`, `test/unit/daemon/dispatcher_test.rb`, and `test/integration/run_stage_action_test.rb` cover the merged-finalize-error archive path that uses `pr_state`.

## Backlinks

- [[cli]] · [[dependencies]]
- [[commands/stage_action]] · [[commands/daemon]]
- [[stages/open-pr]] · [[stages/finalize]]
- [[modules/babysitter]] · [[modules/daemon]]
