---
title: Hive::Worktree
type: module
source: lib/hive/worktree.rb
created: 2026-04-25
updated: 2026-07-18
tags: [worktree, git, pointer, dependencies]
---

**TLDR**: Wrapper around `git worktree add/remove/list` with a YAML pointer file (`worktree.yml`) inside the task folder, plus path-prefix validation that rejects pointers outside the configured `worktree_root`.

## Class shape

```ruby
Hive::Worktree.new(project_root, slug, worktree_root: nil)
#path   → "<worktree_root>/<slug>"
#exists? → bool (sees both filesystem dir and `git worktree list`)
#create!(branch_name, default_branch:, base_override: nil) → :created
#remove! → :removed
#write_pointer!(task_folder, branch_name, execute_base_head: nil) → writes worktree.yml
```

Class methods:

```ruby
Hive::Worktree.read_pointer(task_folder) → Hash | nil
Hive::Worktree.validate_pointer_path(path, expected_root) → expanded_path | raises
Hive::Worktree.materialize_pr(repo_root:, pr_number:, path:, branch:) → {path:, branch:, head_sha:}
```

## `worktree_root` resolution

If passed explicitly, that's used. Otherwise:

1. `cfg["worktree_root"]` from the project's `.hive-state/config.yml`.
2. Fallback: `<base>/<project_name>.worktrees`, computed by `Hive::Worktree.default_worktree_root(project_name)`. The `<base>` is `Hive::Worktree.worktree_base`, which reads `ENV["HIVE_WORKTREE_BASE"]` and defaults to `~/Dev`.

`File.expand_path`-ed so `~` works.

### `HIVE_WORKTREE_BASE` override

`Hive::Worktree.worktree_base` returns `ENV["HIVE_WORKTREE_BASE"] || File.expand_path("~/Dev")`, and every fallback site (`worktree.rb`, `task.rb`, `diagnosis_agent.rb`, `stages/execute.rb`, `stages/review.rb`, `commands/init.rb`) routes the default through `default_worktree_root`. The env override exists so the test suite can point the default base at a tmp sandbox (`test_helper.rb` sets `HIVE_WORKTREE_BASE ||= Dir.mktmpdir("hive-test-wtbase")`); previously the hardcoded `~/Dev/<project>.worktrees` fallback seeded the developer's real `~/Dev` with thousands of `hive-test<...>.worktrees` dirs. When unset, behavior is identical to the old hardcoded `~/Dev` default.

## `create!(branch_name, default_branch:, base_override: nil)`

1. `mkdir -p` the parent of `path`.
2. Probe `git show-ref --verify refs/heads/<branch_name>`:
   - If it exists with no stacked `base_override`, run `git worktree add <path> <branch_name>` (attach to existing branch).
   - If it exists with a stacked `base_override`, `empty_placeholder?` measures `git rev-list --count <base>..<branch_name>` against **both** default refs that exist — `origin/<default>` (when its tracking ref `refs/remotes/origin/<default>` exists) and local `<default>` — and treats the branch as an empty placeholder if it carries **no unique commits beyond either** ref. Consulting both refs catches placeholders left by drift in either direction: one created from `origin/<default>` (via `freshest_base`) sits ahead of a lagging local default, while one created from a local default that runs ahead of a stale origin (`freshest_base`'s fetch-failure fallback) sits ahead of `origin/<default>` — measuring against only one ref would misread the other as carrying work. This emptiness check is a *heuristic* and its base differs from the origin→local→default base the branch is recreated on. When some ref measures zero, Hive deletes the branch with `git branch -D <branch_name>` and falls through to the normal first-creation path below. If every measurable ref is non-zero the branch is preserved and attached as-is; a branch is deleted only on positive proof of emptiness, so any git error skips that ref (warned to stderr) rather than counting as proof, and if no default ref could be measured the branch is preserved (fail-closed) and warned. Delete failure raises `Hive::WorktreeError` naming the branch (and hinting it may be checked out in another worktree).
   - If not, resolve the base via `base_override` when present, otherwise `freshest_base(default_branch)` (see below), then run `git worktree add <path> -b <branch_name> <base>`.
3. On non-zero exit, raise `Hive::WorktreeError` with the captured stderr.

This handles re-attaching to a previously-created branch (e.g. after manually deleting a worktree) without losing history, while allowing dependency-stacked empty placeholders to be recreated on the intended prerequisite base.

### `freshest_base(default_branch)` — origin-first base resolution

New branches always start at `origin/<default>` (after a quick fetch) rather than local `<default>`. The reason is concrete: a contributor who hasn't pulled in a while has a stale local default — `git worktree add -b <slug> <local_default>` would silently produce a worktree missing every upstream commit, and reviewers in 5-review would surface those missing commits as phantom deletions (this was the agent-plugins-was-7-commits-behind incident). Auto-rebase (PR #69) handles drift in long-running worktrees; this handles drift at *creation* time.

The helper:
1. Checks `git config remote.origin.url` — if no `origin` is configured (early-stage repos, internal forks without upstream), return `default_branch` (local fallback). No fetch attempted.
2. Runs an explicit `+refs/heads/<default_branch>:refs/remotes/origin/<default_branch>` fetch. Fully qualifying the source prevents a same-named tag from shadowing the branch. The fetch uses non-interactive env (`GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10"`, plus HTTPS low-speed limits), a 60-second absolute deadline, a bounded 64 KiB capture per stream, and process-group TERM/KILL cleanup so a connected-but-stalled transport cannot hang worktree creation or patrol.
3. On fetch failure (network down, auth missing, dead remote), warn to stderr (`[hive] worktree base: fetch origin <default> failed (<err>); branching from local <default>`) and return `default_branch` (fall back). The worktree is still created so the operator can keep working offline.
4. On fetch success, return `"origin/#{default_branch}"`.

Local `<default>` is never modified — any unpushed commits there are preserved. Only the new feature branch's starting point is affected.

### Dependency base override

`base_override` is used by [[modules/task_dependencies]] when a dependent task
enters `4-execute`. Hive tries to fetch and branch from
`origin/<base_override>` so stacked tasks start from their prerequisite branch.
If there is no origin, the fetch fails, or the remote branch is unavailable,
Hive next checks local `refs/heads/<base_override>` and stacks on that local
branch when present. It warns and falls back through `freshest_base(default_branch)`
only when neither the remote nor local prerequisite branch is available.

## `remove!`

`git -C <project_root> worktree remove <path>`. Raises `WorktreeError` on failure (most commonly when the worktree has uncommitted changes — git refuses to remove dirty worktrees without `--force`).

## `materialize_pr`

`materialize_pr` is the shared fork-agnostic PR-head materializer for `hive review --pr` and the babysitter. It runs:

```bash
git -C <repo> fetch origin +pull/<n>/head:refs/<branch>
git -C <repo> worktree add -B <branch> <path> refs/<branch>
git -C <path> rev-parse HEAD
```

The caller chooses `path` and `branch`; ad-hoc review uses the normal `worktree_root/<slug>` path and branch `hive/review/pr-N`, while babysitter keeps its own babysitter worktree path. The returned `head_sha` lets callers compare the materialized checkout to GitHub's `headRefOid`. Failures raise `Hive::WorktreeError`.

## `exists?`

Two checks: `File.directory?(path)` AND `path ∈ git worktree list --porcelain`. Both must be true. This catches the "directory deleted via Finder/`rm -rf`" case where git still thinks the worktree exists but the filesystem doesn't, and also the inverse (filesystem dir but no git registration).

## Pointer file

`write_pointer!` writes `<task_folder>/worktree.yml`:

```yaml
path: /home/asterio/Dev/<project>.worktrees/<slug>
branch: <slug>
created_at: 2026-04-25T10:23:45Z
execute_base_head: <sha>   # optional; set by 4-execute for commit-baseline checks
```

`read_pointer` parses with `YAML.safe_load` and validates the result is a Hash; raises `WorktreeError` otherwise. `Hive::Stages::Base.worktree_pointer_or_exit` owns the stricter stage-entry policy shared by open-PR and finalize: the pointer must contain `path`, that directory must still exist, and either failure preserves the established warning and exit status 1.

`execute_base_head` records the worktree HEAD immediately after 4-execute creates the task branch. Execute completion compares later HEADs against this baseline, not just against the current spawn's starting HEAD, so a dirty-worktree pause can be recovered by cleaning the worktree without requiring a second empty commit.

## Path-prefix validation

`validate_pointer_path(path, expected_root)`:

1. `File.expand_path` both.
2. Require `path == expected_root` OR `path.start_with?(expected_root + File::SEPARATOR)`.
3. Otherwise raise `WorktreeError` with both paths.

This prevents an agent (with Write access to `worktree.yml`) from setting `path: ../../etc/passwd` and then having a later `Worktree#remove!` walk into a path-traversal attack.

## Used by

- `Stages::Execute#run_init_pass` — creates the worktree, writes the pointer, validates the prefix.
- `Stages::Execute#run_iteration_pass` — re-reads the pointer, re-validates.
- `Stages::OpenPr#run!` — uses the shared stage-entry pointer validator before `git push` runs in the worktree.
- `Stages::Finalize#run!` — uses the same validator before verifying the final branch state.
- `Stages::Done#run!` — reads pointer to print cleanup instructions.
- `Hive::Commands::AdhocReview` — materializes a PR head at the normal worktree root before creating a synthetic `6-review` task.
- `Hive::Babysitter::Worktree` — delegates PR-head materialization here while keeping babysitter-specific cleanup and fork policy around it.

## Tests

- `test/unit/worktree_test.rb` — create attach-vs-new, dependency override stacking (incl. narrow-refspec and origin-ahead-of-local **and** local-ahead-of-origin placeholders), explicit remote-head fetching despite a same-named tag, stalled-transport process-group timeout, empty placeholder re-pointing, fail-closed preservation when the emptiness check errors, local-only prerequisite fallback, real-commit preservation, PR-head materialization/retry/failure handling, delete-failure errors, `local_branch_ref_exists?` blank-name guard, remove, exists?, pointer round-trip, prefix-validation rejection.

## Backlinks

- [[modules/git_ops]]
- [[stages/execute]] · [[stages/open-pr]] · [[stages/finalize]] · [[stages/done]]
- [[state-model]]
