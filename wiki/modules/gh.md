---
title: Hive::Gh
type: module
source: lib/hive/gh.rb, lib/hive/gh/repository_identity.rb, lib/hive/managed_git.rb
created: 2026-06-08
updated: 2026-07-22
tags: [github, gh, module, pr]
---

**TLDR**: `Hive::Gh` is the shared GitHub CLI / git transport for PR publication, finalization, review mirroring, babysitter context, authentication, and repository identity. It wraps `gh`/`git` subprocesses with non-interactive environment defaults, a bounded network timeout, typed return structs, and fail-loud JSON parsing. `Hive::Gh::RepositoryIdentity` owns the strict GitHub host and owner/name validation used by both the transport and architecture patrol. Architecture-patrol-specific issue, merged-PR intake, and publication-proof protocol lives behind `Hive::RefactorPatrol::GithubGateway` instead of widening this global helper.

## API Map

| API | Purpose |
|-----|---------|
| `ensure_authenticated!(cfg = nil, host: nil, timeout_sec: nil)` | Runs `gh auth status`, with `--hostname` when an exact host is supplied; raises `Hive::GhError` when authentication is missing. Architecture patrol passes the remaining slice of its one monotonic remote-operation deadline through `timeout_sec`. |
| `push_branch(worktree_path, branch, cfg: nil, remote: "origin", ...)` | Runs `git push` and returns `PushResult(success:, stdout:, stderr:)`; supports upstream tracking plus exact expected-OID and expected-absence leases. Finalize keeps the default `-u origin` path, while architecture patrol supplies its captured URL with upstream writes disabled. |
| `push_branch!(worktree_path, branch, cfg: nil, remote: "origin", ...)` | Hard-fail wrapper around `push_branch`; architecture patrol binds it to one already-validated URL instead of re-resolving mutable `origin`. |
| `remote_branch_oid(worktree_path, branch, cfg: nil, remote: "origin", managed: false)` | Reads one exact `refs/heads/<branch>` OID through `git ls-remote`; validates the branch/response and can query the same captured URL later used for push. Managed draft-PR callers select the hardened `Hive::ManagedGit` process boundary. |
| `push_exact_oid(worktree_path, head_oid, branch, ...)` | Managed draft-PR-only publication through `Hive::ManagedGit`: pushes `<validated-oid>:refs/heads/<branch>` with an ordinary non-force refspec. It never sets upstream state and has no force/lease mode. |
| `create_draft_pr(..., head:, base:, title:, body:)` | Creates one PR with explicit repository, `--draft`, plain head branch, base, title, and a mode-0600 temporary `--body-file` that is removed on every exit path. The response is not publication proof; the caller must reconcile PR identity. |
| `origin_push_url(worktree_path, cfg: nil, timeout_sec: nil)` | Reads `git remote get-url --push --all origin` and requires exactly one record. Multiple push URLs fail closed because a normal named-remote push can target all of them. Architecture patrol supplies its remaining project-step deadline. |
| `lookup_prs_for_branch(worktree_path, branch, repository: nil, host: nil, cfg: nil)` | Runs `gh pr list --head <branch> --state all --json ...` from the worktree cwd, optionally pinned to an explicit GitHub/GHES repository. Fail-loud on CLI or JSON shape errors. |
| `lookup_existing_pr(...)` | Returns only `OPEN` PRs from `lookup_prs_for_branch`; closed/merged PRs are excluded from the normal open-pr path. |
| `lookup_merged_pr(..., head_oid: nil)` | Returns a `MERGED` PR, optionally requiring `headRefOid` to match the current local `HEAD`. [[stages/open-pr]] uses this for already-merged branch recovery. |
| `pr_state(pr_url, cfg: nil)` | Runs `gh pr view <url> --json state` and returns the state string. `Hive::Commands::StageAction` uses it to re-confirm a daemon-only merged-finalize-error archive recovery before moving the task to `9-done`. |
| `pr_metadata(number, cfg: nil, chdir: nil)` | Runs `gh pr view <n> --json number,url,baseRefName,headRefOid,isCrossRepository,state` and returns `PrMetadata`. `Hive::Commands::AdhocReview` uses it to confirm the PR exists, record declared base/head state, and cross-check the materialized worktree HEAD. The load-bearing `chdir:` kwarg runs the `gh` call in the resolved project root because `gh` has no `-C`; this makes `hive review --pr N --project NAME` query the selected repository instead of the caller's cwd. |
| `list_open_prs(worktree_path, cfg: nil)` | Runs `gh pr list --state open --limit 1000` and includes `mergeStateStatus`; [[modules/babysitter]] uses that field to prioritize dirty/conflicted PRs before age. |
| `repo_name_with_owner(worktree_path, cfg: nil)` / `repository_identity(worktree_path, cfg: nil, timeout_sec: nil)` | Parse the actual origin push URL into canonical `owner/repo` plus host. They do not trust ambient `GH_REPO` or `gh repo view`, so GitHub Enterprise, duplicate registration, and repository drift gates bind to the Git target. The optional timeout is threaded through the underlying origin lookup. |
| `Gh::RepositoryIdentity.validated_repository_slug` / `validated_github_host` / `github_repository_target` | Enforce one strict owner/name and hostname-only policy for both normal GitHub transport and architecture-patrol remote operations. Invalid values retain the established `Hive::GhError` messages. |
| `pr_status_rollup` / `pr_failing_job_logs` | Fetch PR merge/check state and tail-clipped failing job logs for babysitter repair context. |
| `pr_diff_stat` / `pr_base_divergence` | Fetch base and compute diff/divergence context for babysitter prompts. `pr_base_divergence` is best-effort and returns blank fields on git hiccups. |
| `digest_merged_pr_candidates(repository:, host:, window_start:, cfg:)` | Exhaustively paginate closed PR REST rows by descending `updated_at`, validate monotonic pages, detect traversal caps, and return complete candidates for London-window filtering without the Search API's 1,000-row cap. |
| `digest_repository_metadata` / `digest_pr_detail` / `digest_pr_diff` / `digest_pr_files` | Fetch explicit-host repository metadata plus canonical PR body/identity/optional metrics, raw GitHub diff, and complete paginated file identities. These fail loudly so [[modules/digest]] can make required evidence repository-atomic. |
| `pr_frontmatter(path)` | Safe YAML frontmatter reader for `pr.md`; malformed YAML warns and returns `{}`. |
| `scan_pr_for_secrets(state_file:, pr_url:, cfg: nil)` | Scans local state-file text plus remote PR body for `Hive::SecretPatterns`; returns `ScanResult` with `fetch_failed` instead of silently treating remote fetch errors as clean. |
| `capture3(*cmd, chdir: nil, cfg: nil, timeout_sec: nil)` | Shared subprocess wrapper used by the helpers above. |

## Architecture-patrol adapter

`Hive::RefactorPatrol::GithubGateway`
(`lib/hive/refactor_patrol/github_gateway.rb`) owns the remote protocol that is
specific to durable architecture patrol. It accepts `Hive::Gh` as an injected
transport, using only shared authentication, repository identity, and
`capture3` behavior from that module. Its repository/host inputs pass through
the same `Hive::Gh::RepositoryIdentity` validator as ordinary transport calls.
The split keeps feature-specific response
shapes and fail-closed reconciliation rules out of unrelated GitHub callers.

| Adapter API | Purpose |
|-------------|---------|
| `issues_for_repository` / `issues_with_marker` / `create_issue` | Validate the complete exact-host issue inventory, exclude pull requests, reconcile exact markers, and create a bounded body through a temporary file. |
| `merged_pr_details` | Resolve one merged PR plus its complete paginated file/status/rename manifest against the checkout's canonical host and repository. Identity lookup, authentication, metadata, and files share one monotonic deadline. |
| `merged_prs_page` | Fetch and validate one cursor-addressed GraphQL page of strictly typed merged-PR occurrence identities for catch-up, using stable creation order and one exact ISO timestamp `merged:<lower>..<upper>` qualifier for the fixed merge-time window. |
| `verify_pr_identity!` | Re-read a newly created patrol PR and require the expected URL, repository, OPEN non-draft state, branch, head OID, and base before handoff. |

## Subprocess Contract

`capture3` uses `Process.spawn` with argv-form commands, never shell interpolation. It sets `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` so unattended daemon/babysitter paths fail instead of blocking on terminal prompts. The timeout comes from `cfg["gh"]["network_timeout_sec"]` when present and positive, otherwise defaults to `NETWORK_TIMEOUT_SEC = 60`. Each capture owns a process group, and the deadline covers both direct-process exit and stdout/stderr drain; timeout handling sends TERM and then KILL to the group. A helper that outlives `gh` while retaining a pipe therefore cannot stall a daemon reader indefinitely.

Push and remote-OID helpers validate branch names before constructing refspecs,
and refuse empty, option-shaped, NUL-bearing, or newline-bearing remote targets.
Dynamic refs, remotes, and OIDs remain discrete `execve` arguments; the
Brakeman ignore entries document those argv-form command-injection false
positives rather than masking an unvalidated shell boundary.

`gh` does not support `-C`, so PR CLI calls that depend on repository context use `chdir: worktree_path`. Git commands still pass explicit worktree arguments where the command supports them.

## Recovery Boundaries

Normal workflow commands do not treat a PR URL as sufficient proof that a task can advance. `lookup_existing_pr` intentionally ignores closed and merged PRs; `scan_pr_for_secrets` fails loud when the remote PR body cannot be fetched; and `pr_state` re-checks GitHub state immediately before the internal `hive archive --recover-merged-error-reason` path accepts an `8-finalize` `ERROR` marker. That recovery path also requires the current marker's `reason=` to exactly match the daemon-provided flag, so a stale merge-watch entry cannot advance a newer error. Ad-hoc review is similarly explicit: `pr_metadata` is number-based and repository-context-driven by `gh`; the project still comes from the current registered checkout or `--project`, not from parsing the PR URL host/path.

Managed `handoff: draft_pr` stages use the narrower exact-OID APIs. The
controller records mutation intent before each push/create attempt, observes
the remote branch and all PR states before and after mutation, and accepts an
OPEN draft or human-promoted OPEN PR only when repository/base/head identity
matches the receipt. It never calls `push_branch`, force-pushes, marks a PR
ready, edits, closes, merges, releases, publishes, or deploys.
Post-agent Git commands are allow-listed by `Hive::ManagedGit` under a reduced
environment and fixed config overrides. Repository hooks/fsmonitor/external
diff or textconv, `ext`/`file` transports, inherited Git config, and arbitrary
credential/SSH helper selection cannot execute in controller context; GitHub
HTTPS credentials are delegated only to `gh auth git-credential`, while SSH
uses the controller's agent socket and standard client.

Architecture patrol strengthens that boundary for external transactions through
`Hive::RefactorPatrol::GithubGateway`. The
source manifest supplies repository identity plus a PR URL whose host is
authoritative; lookup validates branch, base, head OID, hidden action marker,
and exact host/repository identity. A push may
replace a remote OID only with an exact force-with-lease tied to a proven
superseded patch generation, while a new branch uses an exact absence lease.
That authority is derived from the durable action ledger, not from the remote
branch name: the old publication attempt must have immutable `push_complete`
proof for that commit plus an immutable pre-create supersession record.
`PrOpener` passes that exact old commit to `Hive::Gh.push_branch!` as the
expected remote OID; `Hive::Gh` enforces the lease but does not decide which
generation is replaceable. Any unrelated OID remains a conflict.
The publisher captures one validated origin push URL and reuses it for OID
lookup and push; multiple URLs or later named-remote rewrites cannot broaden or
redirect that transaction. An arbitrary existing branch is a conflict.
Existing same-branch OPEN PRs are reconcilable only when `isDraft` is explicitly false;
an OPEN draft is conflicting remote state rather than proof of publication.
After creation, `verify_pr_identity!` independently proves the PR still names
the validated patch before any `6-review` handoff. Issue reconciliation reads
the complete open/closed inventory and prefers an exact v2 marker. Only when no
marker matches may the caller apply architecture patrol's strict markerless
legacy-body parser and pairwise semantic-family compatibility; malformed or
ambiguous historical matches fail closed. These helpers provide remote
evidence, while durable creation intent, ownership/handoff fences, and fencing
generation remain owned by [[commands/refactor-patrol]]'s job aggregate.

## Tests

- `test/unit/gh_test.rb` covers shared frontmatter, secret-scan, PR lookup, remote-OID/lease, immutable exact-OID non-force push, restrictive draft-PR body tempfiles, repository identity, subprocess, and status APIs. The same file exercises `GithubGateway`'s created-PR proof, exact-host merged-PR detail intake, and GraphQL pagination through an injected transport, including the single-qualifier exact timestamp range used for merge catch-up.
- `test/unit/gh_issue_helpers_test.rb` covers `GithubGateway`'s full paginated inventory, pull-request exclusion, exact-marker delegation, explicit host/repository issue creation, and malformed/cross-repository fail-closed behavior. `test/unit/refactor_patrol/issue_filer_test.rb` covers exact-marker precedence plus strict legacy semantic grouping, malformed historical bodies, and pairwise-ambiguous matches.
- `test/unit/refactor_patrol/pr_opener_test.rb` pins exact absence/OID leases and pre-create trunk checks. `test/unit/refactor_patrol/action_runner_test.rb` covers the real-git crash/restart path from a durably pushed stale generation through supersession, exact old-OID replacement, one verified PR, and one mandatory review handoff.
- `test/unit/daemon/pr_merge_watcher_test.rb`, `test/unit/daemon/dispatcher_test.rb`, and `test/integration/run_stage_action_test.rb` cover the merged-finalize-error archive path that uses `pr_state`.

## Backlinks

- [[cli]] · [[dependencies]]
- [[commands/stage_action]] · [[commands/daemon]]
- [[stages/open-pr]] · [[stages/finalize]]
- [[modules/babysitter]] · [[modules/daemon]]
- [[commands/refactor-patrol]]
