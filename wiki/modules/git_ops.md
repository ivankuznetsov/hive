---
title: Hive::GitOps
type: module
source: lib/hive/git_ops.rb
created: 2026-04-25
updated: 2026-04-25
tags: [git, init, commit]
---

**TLDR**: Project-scoped git operations: detect default branch, bootstrap the orphan `hive/state` worktree at `<project>/.hive-state/`, append `/.hive-state/` to master's `.gitignore`, and run `git add && git commit` inside the hive-state worktree.

## Constants

- `HIVE_BRANCH = "hive/state"` — the orphan branch name.
- `HIVE_STATE_GITIGNORE` — patterns for `<.hive-state>/.gitignore` so per-task `.lock`, `.lock.tmp.*`, `*.markers-lock`, and `.commit-lock` files don't get tracked.

The bootstrap reads stage names from `Hive::Stages::DIRS` (see [[modules/stages]]); there is no module-local stage-list constant.

## Constructor

```ruby
Hive::GitOps.new(project_root)
```

`@project_root` is `File.expand_path`-ed. `#hive_state_path` returns `<project_root>/.hive-state`.

## `detect_default_branch`

Memoised. Tries in order:

1. `git -C <root> symbolic-ref refs/remotes/origin/HEAD` → strip `refs/remotes/origin/` prefix.
2. `git -C <root> rev-parse --abbrev-ref HEAD` (skipped if it returns `"HEAD"`).
3. `git config init.defaultBranch`.
4. Literal `"master"`.

This handles repos with no remote (steps 2/3) and brand-new repos (step 4).

## `hive_state_init`

Idempotent bootstrap. Returns `:existed` if the `hive/state` branch already exists (after ensuring its worktree is attached). Otherwise:

1. `git worktree add --no-checkout --detach <hive_state_path> <default_branch>` — attach a worktree without checking out anything.
2. `cd <hive_state_path>; git checkout --orphan hive/state` — replace the worktree's HEAD with a new orphan branch.
3. `git rm -rf .` plus `FileUtils.rm_rf` glob cleanup of all visible files and dotfiles (preserving `.git`).
4. Create stage subdirs `stages/1-inbox/.gitkeep`, …, `stages/7-done/.gitkeep`, plus `logs/.gitkeep`.
5. `git add . && git commit -m "hive: bootstrap"`.

Returns `:created`.

## `add_hive_state_to_master_gitignore!`

Appends `/.hive-state/` to `<project>/.gitignore` (idempotent: returns `:already` if the line is present). Then:

1. `git -C <project> add .gitignore`.
2. `git -C <project> commit -m "chore: ignore .hive-state worktree"`.

This is the *only* commit Hive ever makes on master. After this, all hive activity goes to `hive/state`.

## `hive_commit(stage_name:, slug:, action:)`

Stage runners produce a `commit:` field; `Commands::Run` calls this method inside the per-project commit lock.

1. `git -C <hive_state_path> add .` (only the hive-state worktree, never master).
2. `git diff --cached --quiet`. If exit 0 (nothing staged), return `:nothing_to_commit`.
3. Otherwise commit with message `hive: <stage_name>/<slug> <action>` and return `:committed`.

Empty diffs are silently skipped (e.g. an `inbox.run!` that deliberately does nothing).

## `run_git!` / `run_git_quiet`

`run_git!(*args)` invokes `Open3.capture3("git", *args)` and raises `Hive::GitError` on non-zero exit. `run_git_quiet` returns the tuple unchanged for cases where empty-error is expected (e.g. `git rm -rf .` on a directory with no tracked files).

## Tests

- `test/unit/git_ops_test.rb` — default-branch detection across remote/no-remote/no-commits scenarios; orphan worktree bootstrap; idempotent gitignore; commit skipping on empty diff.

## Backlinks

- [[commands/init]] · [[commands/run]] · [[commands/new]]
- [[modules/worktree]]
- [[state-model]]
