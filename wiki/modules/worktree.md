---
title: Hive::Worktree
type: module
source: lib/hive/worktree.rb
created: 2026-04-25
updated: 2026-05-13
tags: [worktree, git, pointer]
---

**TLDR**: Wrapper around `git worktree add/remove/list` with a YAML pointer file (`worktree.yml`) inside the task folder, plus path-prefix validation that rejects pointers outside the configured `worktree_root`.

## Class shape

```ruby
Hive::Worktree.new(project_root, slug, worktree_root: nil)
#path   → "<worktree_root>/<slug>"
#exists? → bool (sees both filesystem dir and `git worktree list`)
#create!(branch_name, default_branch:) → :created
#remove! → :removed
#write_pointer!(task_folder, branch_name, execute_base_head: nil) → writes worktree.yml
```

Class methods:

```ruby
Hive::Worktree.read_pointer(task_folder) → Hash | nil
Hive::Worktree.validate_pointer_path(path, expected_root) → expanded_path | raises
```

## `worktree_root` resolution

If passed explicitly, that's used. Otherwise:

1. `cfg["worktree_root"]` from the project's `.hive-state/config.yml`.
2. Fallback: `<base>/<project_name>.worktrees`, computed by `Hive::Worktree.default_worktree_root(project_name)`. The `<base>` is `Hive::Worktree.worktree_base`, which reads `ENV["HIVE_WORKTREE_BASE"]` and defaults to `~/Dev`.

`File.expand_path`-ed so `~` works.

### `HIVE_WORKTREE_BASE` override

`Hive::Worktree.worktree_base` returns `ENV["HIVE_WORKTREE_BASE"] || File.expand_path("~/Dev")`, and every fallback site (`worktree.rb`, `task.rb`, `diagnosis_agent.rb`, `stages/execute.rb`, `stages/review.rb`, `commands/init.rb`) routes the default through `default_worktree_root`. The env override exists so the test suite can point the default base at a tmp sandbox (`test_helper.rb` sets `HIVE_WORKTREE_BASE ||= Dir.mktmpdir("hive-test-wtbase")`); previously the hardcoded `~/Dev/<project>.worktrees` fallback seeded the developer's real `~/Dev` with thousands of `hive-test<...>.worktrees` dirs. When unset, behavior is identical to the old hardcoded `~/Dev` default.

## `create!(branch_name, default_branch:)`

1. `mkdir -p` the parent of `path`.
2. Probe `git show-ref --verify refs/heads/<branch_name>`:
   - If it exists, run `git worktree add <path> <branch_name>` (attach to existing branch).
   - If not, **resolve the freshest base** via `freshest_base(default_branch)` (see below), then run `git worktree add <path> -b <branch_name> <base>`.
3. On non-zero exit, raise `Hive::WorktreeError` with the captured stderr.

This handles re-attaching to a previously-created branch (e.g. after manually deleting a worktree) without losing history.

### `freshest_base(default_branch)` — origin-first base resolution

New branches always start at `origin/<default>` (after a quick fetch) rather than local `<default>`. The reason is concrete: a contributor who hasn't pulled in a while has a stale local default — `git worktree add -b <slug> <local_default>` would silently produce a worktree missing every upstream commit, and reviewers in 5-review would surface those missing commits as phantom deletions (this was the agent-plugins-was-7-commits-behind incident). Auto-rebase (PR #69) handles drift in long-running worktrees; this handles drift at *creation* time.

The helper:
1. Checks `git config remote.origin.url` — if no `origin` is configured (early-stage repos, internal forks without upstream), return `default_branch` (local fallback). No fetch attempted.
2. Runs `git fetch origin <default_branch>` with non-interactive env (`GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10"` — same shape as `GitOps#fetch_default_branch`) so credential prompts cannot hang worktree creation.
3. On fetch failure (network down, auth missing, dead remote), warn to stderr (`[hive] worktree base: fetch origin <default> failed (<err>); branching from local <default>`) and return `default_branch` (fall back). The worktree is still created so the operator can keep working offline.
4. On fetch success, return `"origin/#{default_branch}"`.

Local `<default>` is never modified — any unpushed commits there are preserved. Only the new feature branch's starting point is affected.

## `remove!`

`git -C <project_root> worktree remove <path>`. Raises `WorktreeError` on failure (most commonly when the worktree has uncommitted changes — git refuses to remove dirty worktrees without `--force`).

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

`read_pointer` parses with `YAML.safe_load` and validates the result is a Hash; raises `WorktreeError` otherwise.

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
- `Stages::OpenPr#run!` — reads pointer for the worktree path; `git push` runs there.
- `Stages::Finalize#run!` — reads pointer to verify the final branch state before wrapping up the PR.
- `Stages::Done#run!` — reads pointer to print cleanup instructions.

## Tests

- `test/unit/worktree_test.rb` — create attach-vs-new branch, remove, exists?, pointer round-trip, prefix-validation rejection.

## Backlinks

- [[modules/git_ops]]
- [[stages/execute]] · [[stages/open-pr]] · [[stages/finalize]] · [[stages/done]]
- [[state-model]]
