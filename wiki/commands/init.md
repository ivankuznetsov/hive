---
title: hive init
type: command
source: lib/hive/commands/init.rb
created: 2026-04-25
updated: 2026-04-25
tags: [command, bootstrap, git]
---

**TLDR**: `hive init [PATH]` bootstraps a project for hive: creates the orphan `hive/state` branch, attaches it as a worktree at `<project>/.hive-state/`, scaffolds stage folders and `config.yml`, ignores `.hive-state/` in master, and registers the project globally.

## Usage

```
hive init [PROJECT_PATH] [--force]
```

`PROJECT_PATH` defaults to `Dir.pwd`. `--force` skips the clean-tree check.

## Preconditions

1. Path must be a git repository — `git -C <path> rev-parse --git-common-dir` must succeed.
2. Path must be the **main checkout**, not a worktree. The check compares git's common-dir against `<path>/.git`. Running inside an existing worktree exits 1 with `"target appears to be inside a worktree"`.
3. Working tree must be clean unless `--force` is passed; otherwise exit 1 with `"uncommitted changes"`.
4. `hive/state` branch must not already exist; if it does, prints `"already initialized"` and exits 2 (idempotent).

## Steps performed

1. **Create orphan worktree** via `Hive::GitOps#hive_state_init` (`lib/hive/git_ops.rb:34`):
   - `git worktree add --no-checkout --detach <path>/.hive-state <default_branch>`
   - `git -C .hive-state checkout --orphan hive/state`
   - `git rm -rf .` plus glob cleanup of any leftover dotfiles (preserving `.git`).
   - Create `stages/{1-inbox,2-brainstorm,3-plan,4-execute,6-pr,7-done}/` with `.gitkeep` markers and `logs/.gitkeep`.
   - Initial commit `hive: bootstrap` on `hive/state`.
2. **Render `<path>/.hive-state/config.yml`** from `templates/project_config.yml.erb`. Skipped if the file already exists.
3. **Ignore `.hive-state/` on master** via `GitOps#add_hive_state_to_master_gitignore!`: appends `/.hive-state/` to `.gitignore` (idempotent), then commits `chore: ignore .hive-state worktree` on master.
4. **Register globally** via `Hive::Config.register_project(name: basename(path), path: path)`, writing into `~/Dev/hive/config.yml`.
5. Print summary: project name, default branch, hive-state path, worktree root, and a `next:` line with the `hive new ...` invocation.

## Default-branch detection

`GitOps#detect_default_branch` (`lib/hive/git_ops.rb:92`) tries:

1. `git symbolic-ref refs/remotes/origin/HEAD` → strip `refs/remotes/origin/` prefix.
2. Fallback: `git rev-parse --abbrev-ref HEAD` (if not detached).
3. Fallback: `git config init.defaultBranch`.
4. Final fallback: literal `"master"`.

This branch is what the orphan worktree is initially based on, and what feature worktrees are branched from.

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `not a git repository` | path isn't a git repo | `git init` first |
| `target appears to be inside a worktree` | running from a feature worktree | run on main checkout |
| `uncommitted changes` | dirty working tree | commit/stash, or pass `--force` |
| `already initialized` (exit 2) | `hive/state` already exists | nothing to do |

## Tests

- `test/integration/init_test.rb` covers all five preconditions plus the `--force` path and the idempotent double-init.

## Backlinks

- [[cli]] · [[commands/run]]
- [[modules/git_ops]] · [[modules/config]]
- [[state-model]]
