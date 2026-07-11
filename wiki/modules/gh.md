---
title: Hive::Gh
type: module
source: lib/hive/gh.rb
created: 2026-06-08
updated: 2026-07-11
tags: [github, gh, module, pr]
---

**TLDR**: `Hive::Gh` is the shared GitHub CLI / git network helper for PR publication, finalization, review mirroring, babysitter context, and architecture-patrol merge/publication recovery. It wraps `gh`/`git` subprocesses with non-interactive environment defaults, a bounded network timeout, explicit GitHub/GHES repository identity, typed return structs, and fail-loud JSON parsing so callers do not confuse a remote outage with a clean PR state.

## API Map

| API | Purpose |
|-----|---------|
| `ensure_authenticated!(cfg = nil, host: nil)` | Runs `gh auth status`, with `--hostname` when an exact host is supplied; raises `Hive::GhError` when authentication is missing. Used by normal PR stages and exact-host architecture patrol. |
| `push_branch(worktree_path, branch, cfg: nil, remote: "origin", ...)` | Runs `git push` and returns `PushResult(success:, stdout:, stderr:)`; supports upstream tracking plus exact expected-OID and expected-absence leases. Finalize keeps the default `-u origin` path, while architecture patrol supplies its captured URL with upstream writes disabled. |
| `push_branch!(worktree_path, branch, cfg: nil, remote: "origin", ...)` | Hard-fail wrapper around `push_branch`; architecture patrol binds it to one already-validated URL instead of re-resolving mutable `origin`. |
| `remote_branch_oid(worktree_path, branch, cfg: nil, remote: "origin")` | Reads one exact `refs/heads/<branch>` OID through `git ls-remote`; validates the branch/response and can query the same captured URL later used for push. |
| `origin_push_url(worktree_path, cfg: nil)` | Reads `git remote get-url --push --all origin` and requires exactly one record. Multiple push URLs fail closed because a normal named-remote push can target all of them. |
| `lookup_prs_for_branch(worktree_path, branch, repository: nil, host: nil, cfg: nil)` | Runs `gh pr list --head <branch> --state all --json ...` from the worktree cwd, optionally pinned to an explicit GitHub/GHES repository. Fail-loud on CLI or JSON shape errors. |
| `lookup_existing_pr(...)` | Returns only `OPEN` PRs from `lookup_prs_for_branch`; closed/merged PRs are excluded from the normal open-pr path. |
| `issues_for_repository(repository:, host:, cfg: nil)` | Fetches every paginated open/closed record from the exact-host REST issues endpoint, validates identity and shape, excludes pull requests, and returns the complete issue inventory. Partial or malformed pages fail closed. |
| `issues_with_marker(repository:, marker:, host:, cfg: nil)` | Filters `issues_for_repository` for one exact full-line marker; retained as the strict marker helper while architecture patrol can inspect the same validated inventory for conservative legacy reconciliation. |
| `create_issue(repository:, title:, body:, host:, cfg: nil)` | Sends Markdown via a temporary body file to an explicit host/repository and rejects an empty or cross-repository response URL. |
| `verify_pr_identity!(pr_url, repository:, host:, branch:, head_oid:, base_branch:, cfg: nil)` | Re-reads a newly created PR from the exact host/repository and requires matching URL/number, OPEN non-draft state, head repository/branch/OID, and base branch before review handoff. |
| `lookup_merged_pr(..., head_oid: nil)` | Returns a `MERGED` PR, optionally requiring `headRefOid` to match the current local `HEAD`. [[stages/open-pr]] uses this for already-merged branch recovery. |
| `merged_pr_details(...)` | Derives exact host/repository from the checkout origin, pins `gh pr view` to that target, validates the returned PR URL/number, and fetches complete file status/rename pages through `gh api --hostname <host>`. |
| `merged_prs_page(repository:, host:, ...)` | Runs host-pinned GraphQL catch-up and validates every returned URL, PR number, and `nameWithOwner` before advancing architecture-patrol high water. |
| `pr_state(pr_url, cfg: nil)` | Runs `gh pr view <url> --json state` and returns the state string. `Hive::Commands::StageAction` uses it to re-confirm a daemon-only merged-finalize-error archive recovery before moving the task to `9-done`. |
| `pr_metadata(number, cfg: nil, chdir: nil)` | Runs `gh pr view <n> --json number,url,baseRefName,headRefOid,isCrossRepository,state` and returns `PrMetadata`. `Hive::Commands::AdhocReview` uses it to confirm the PR exists, record declared base/head state, and cross-check the materialized worktree HEAD. The load-bearing `chdir:` kwarg runs the `gh` call in the resolved project root because `gh` has no `-C`; this makes `hive review --pr N --project NAME` query the selected repository instead of the caller's cwd. |
| `list_open_prs(worktree_path, cfg: nil)` | Runs `gh pr list --state open --limit 1000` and includes `mergeStateStatus`; [[modules/babysitter]] uses that field to prioritize dirty/conflicted PRs before age. |
| `repo_name_with_owner(worktree_path, cfg: nil)` / `repository_identity(worktree_path, cfg: nil)` | Parse the actual origin push URL into canonical `owner/repo` plus host. They do not trust ambient `GH_REPO` or `gh repo view`, so GitHub Enterprise, duplicate registration, and repository drift gates bind to the Git target. |
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

Normal workflow commands do not treat a PR URL as sufficient proof that a task can advance. `lookup_existing_pr` intentionally ignores closed and merged PRs; `scan_pr_for_secrets` fails loud when the remote PR body cannot be fetched; and `pr_state` re-checks GitHub state immediately before the internal `hive archive --recover-merged-error-reason` path accepts an `8-finalize` `ERROR` marker. That recovery path also requires the current marker's `reason=` to exactly match the daemon-provided flag, so a stale merge-watch entry cannot advance a newer error. Ad-hoc review is similarly explicit: `pr_metadata` is number-based and repository-context-driven by `gh`; the project still comes from the current registered checkout or `--project`, not from parsing the PR URL host/path.

Architecture patrol strengthens that boundary for external transactions. The
source manifest supplies repository identity plus a PR URL whose host is
authoritative; lookup validates branch, base, head OID, hidden action marker,
and exact host/repository identity. A push may
replace a remote OID only with an exact force-with-lease tied to a proven
superseded patch generation, while a new branch uses an exact absence lease.
The publisher captures one validated origin push URL and reuses it for OID
lookup and push; multiple URLs or later named-remote rewrites cannot broaden or
redirect that transaction. An arbitrary existing branch is a conflict.
After creation, `verify_pr_identity!` independently proves the PR still names
the validated patch before any `6-review` handoff. Issue reconciliation reads
the complete open/closed inventory and prefers an exact v2 marker. Only when no
marker matches may the caller apply architecture patrol's strict markerless
legacy-body parser and pairwise semantic-family compatibility; malformed or
ambiguous historical matches fail closed. These helpers provide remote
evidence, while durable creation intent, ownership/handoff fences, and fencing
generation remain owned by [[commands/refactor-patrol]]'s job aggregate.

## Tests

- `test/unit/gh_test.rb` covers frontmatter parsing, secret-scan fetch-failure semantics, open/merged PR lookup contracts, exact remote OIDs/absence leases, single-push-URL enforcement, ambient `GH_REPO` non-authority, repository/host identity, created-PR identity verification, exact-host PR-detail/file intake, host-pinned GraphQL pagination, `pr_state` success/error parsing, `pr_metadata` parsing/error handling/project `chdir:` scoping, `PushResult`, subprocess timeout/termination, `list_open_prs` JSON fields, failing-job log clipping, and malformed JSON failures.
- `test/unit/gh_issue_helpers_test.rb` covers full paginated inventory, pull-request exclusion, exact-marker delegation, explicit host/repository creation, and malformed/cross-repository fail-closed behavior. `test/unit/refactor_patrol/issue_filer_test.rb` covers exact-marker precedence plus strict legacy semantic grouping, malformed historical bodies, and pairwise-ambiguous matches.
- `test/unit/daemon/pr_merge_watcher_test.rb`, `test/unit/daemon/dispatcher_test.rb`, and `test/integration/run_stage_action_test.rb` cover the merged-finalize-error archive path that uses `pr_state`.

## Backlinks

- [[cli]] · [[dependencies]]
- [[commands/stage_action]] · [[commands/daemon]]
- [[stages/open-pr]] · [[stages/finalize]]
- [[modules/babysitter]] · [[modules/daemon]]
- [[commands/refactor-patrol]]
