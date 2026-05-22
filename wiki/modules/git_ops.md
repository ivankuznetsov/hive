---
title: Hive::GitOps
type: module
source: lib/hive/git_ops.rb
created: 2026-04-25
updated: 2026-05-22T13:30:00Z
tags: [git, init, commit]
---

**TLDR**: Project-scoped git operations: detect default branch, inspect HEAD/branch/worktree status, bootstrap the orphan `hive/state` worktree at `<project>/.hive-state/`, append `/.hive-state/` to master's `.gitignore`, commit managed llm-wiki bootstrap files during `hive init`, and run `git add && git commit` inside the hive-state worktree.

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

Tries in order:

1. `origin_default_branch` (see below) — origin/HEAD symref or origin/main/origin/master probe.
2. `git -C <root> rev-parse --abbrev-ref HEAD` (skipped if it returns `"HEAD"`).
3. `git config init.defaultBranch`.
4. Literal `"master"`.

This handles repos with no remote (steps 2/3) and brand-new repos (step 4). Callers that must NOT fall back to the local current branch (e.g. `Hive::Stages::Review.reviewer_compare_ref`, since the local current branch in a `git worktree add` is the task branch and reviewers diffing the task against itself is the phantom-findings bug) call `origin_default_branch` directly and handle the `nil` case explicitly.

## `origin_default_branch`

Returns the project default branch derived from a trusted remote source only:

1. `git -C <root> symbolic-ref refs/remotes/origin/HEAD` → strip `refs/remotes/origin/` prefix.
2. Probe `ref_exists?("refs/remotes/origin/main")`, then `refs/remotes/origin/master`.
3. `nil`.

Both probes use the full `refs/remotes/origin/<branch>` path so a tag named e.g. `origin/main` cannot satisfy the check (rev-parse short-form is ambiguous with `refs/tags/<name>`).

## `ref_exists?(ref)`

Returns `true` when `git -C <root> rev-parse --verify --quiet <ref>` succeeds. Used by `origin_default_branch` to probe remote-tracking refs, and by `Hive::Stages::Review.reviewer_compare_ref` to prefer `origin/<default_branch>` over a stale local ref. Callers checking remote-tracking refs should pass the full `refs/remotes/origin/<branch>` path, not the short form `origin/<branch>`, to avoid tag-name collisions.

## `hive_state_init`

Idempotent bootstrap. Returns `:existed` if the `hive/state` branch already exists (after ensuring its worktree is attached). Otherwise:

1. `git worktree add --no-checkout --detach <hive_state_path> <default_branch>` — attach a worktree without checking out anything.
2. `cd <hive_state_path>; git checkout --orphan hive/state` — replace the worktree's HEAD with a new orphan branch.
3. `git rm -rf .` plus `FileUtils.rm_rf` glob cleanup of all visible files and dotfiles (preserving `.git`).
4. Create stage subdirs `stages/1-inbox/.gitkeep`, …, `stages/9-done/.gitkeep`, plus `logs/.gitkeep`.
5. `git add . && git commit -m "hive: bootstrap"`.

Returns `:created`.

## `add_hive_state_to_master_gitignore!`

Appends `/.hive-state/` to `<project>/.gitignore` (idempotent: returns `:already` if the line is present). Then:

1. `git -C <project> add .gitignore`.
2. `git -C <project> commit -m "chore: ignore .hive-state worktree"`.

This is one of the project-setup commits Hive may make on master/default branch. Runtime task activity still goes to `hive/state`.

## `commit_llm_wiki_bootstrap!`

Stages the managed llm-wiki context paths written by `Hive::LlmWikiBootstrap`:

- `.llm-wiki/config.json`
- `.llm-wiki/refresh-wiki.sh`
- `.llm-wiki/post-commit-refresh.sh`
- `.claude/settings.json`
- `AGENTS.md`
- `CLAUDE.md`
- `wiki/{index,log,gaps,architecture,decisions,dependencies}.md`
- `raw/notes/.gitkeep`

If staging produces a diff, commits `chore: initialize llm-wiki`; otherwise returns `:nothing_to_commit`. `hive init` calls this before installing the runtime post-commit hook so the bootstrap commit does not launch a wiki refresh immediately.

## `hive_commit(stage_name:, slug:, action:)`

Stage runners produce a `commit:` field; `Commands::Run` calls this method inside the per-project commit lock.

1. `git -C <hive_state_path> add .` (only the hive-state worktree, never master).
2. `git diff --cached --quiet`. If exit 0 (nothing staged), return `:nothing_to_commit`.
3. Otherwise commit with message `hive: <stage_name>/<slug> <action>` and return `:committed`.

Empty diffs are silently skipped (e.g. an `inbox.run!` that deliberately does nothing).

## Worktree Inspection Helpers

- `head_sha` returns `git rev-parse HEAD` for the configured root.
- `status_short` returns `git status --short` and raises `GitError` on failure.
- `current_branch` returns `git branch --show-current`, or `nil` for detached HEAD.
- `ancestor?(ancestor, descendant)` wraps `git merge-base --is-ancestor`, returning `true` / `false` for normal ancestry answers and raising `GitError` for command failures.

4-execute uses these helpers after the implementation spawn to verify the worktree stayed on the expected task branch, still descends from the execute baseline, is clean, and has produced an implementation commit before writing `EXECUTE_COMPLETE`.

## `run_git!` / `run_git_quiet`

`run_git!(*args)` invokes `Open3.capture3("git", *args)` and raises `Hive::GitError` on non-zero exit. `run_git_quiet` returns the tuple unchanged for cases where empty-error is expected (e.g. `git rm -rf .` on a directory with no tracked files).

## Tests

- `test/unit/git_ops_test.rb` — default-branch detection across remote/no-remote/no-commits scenarios; orphan worktree bootstrap; idempotent gitignore; commit skipping on empty diff.

## Backlinks

- [[commands/init]] · [[commands/run]] · [[commands/new]]
- [[modules/worktree]]
- [[state-model]]
