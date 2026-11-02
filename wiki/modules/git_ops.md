---
title: Hive::GitOps
type: module
source: lib/hive/git_ops.rb
created: 2026-04-25
updated: 2026-11-02
tags: [git, init, commit]
---

**TLDR**: Project-scoped git operations: detect default branch, inspect HEAD/branch/worktree status, bootstrap the orphan `hive/state` worktree at `<project>/.hive-state/`, append `/.hive-state/` to master's `.gitignore`, commit managed llm-wiki bootstrap files during `hive init`, and serialize scoped commits inside the hive-state worktree.

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
2. `git -C <project> commit -m "chore: ignore .hive-state worktree" -- .gitignore` — pathspec-limited so any unrelated files the user had already staged are not swept into the bootstrap commit and stay staged.

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

Both the staged-emptiness check (`git diff --cached --quiet -- <paths>`) and the commit (`git commit -m "chore: initialize llm-wiki" -- <paths>`) are scoped to exactly those scaffolding paths, so pre-staged unrelated files neither ride along in the bootstrap commit nor mask the check. Returns `:nothing_to_commit` when only the scaffolding paths are unchanged; otherwise commits. `hive init` calls this before installing the runtime post-commit hook so the bootstrap commit does not launch a wiki refresh immediately.

## `hive_commit(stage_name:, slug:, action:, body: nil, pathspecs: nil, allow_empty: false, after_stage: nil)`

For the retained uncertainty and historical evidence, see [Conservative Git index-lock recovery (2026-09-07)](#conservative-git-index-lock-recovery-2026-09-07).

Records a hive-state audit commit. `GitOps` acquires the project commit lock at
this shared mutation seam, so every caller is serialized, including
`Hive::DisplayName::Generator` and Patrol Fix transition commits. Existing
transactional callers may still hold `Hive::Lock.with_commit_lock` around a
larger filesystem-plus-index operation; same-thread, same-process reentrancy
lets the nested `hive_commit` reuse that ownership without deadlocking.

Inside one commit-lock critical section it:

1. Builds the message `hive: <stage_name>/<slug> <action>`, plus an optional second body paragraph when `body:` is present.
2. With no `pathspecs:`, stages only `stages/<stage_name>/<slug>` when that directory exists, plus `logs/` when present. This avoids sweeping unrelated sibling-task changes into the commit.
3. With `pathspecs:`, stages each explicit hive-state-relative pathspec via `git add -A -- <pathspec>` only when the path exists or is already tracked, so deletion commits work without untracked sibling leakage.
4. Invokes optional `after_stage` after all scoped adds and before inspecting or committing the index. Safety-sensitive migrations use this boundary to verify that a raced path did not reappear in either the worktree or staged index; raising aborts before `git commit`.
5. Runs `git diff --cached --quiet`. If exit 0 (nothing staged), returns `:nothing_to_commit`.
6. Otherwise commits and returns `:committed`; `allow_empty: true` adds `--allow-empty`.

Empty diffs are silently skipped (e.g. an `inbox.run!` that deliberately does nothing).

The central lock covers runtime commits after the hive-state worktree exists.
`hive_state_init` remains a separate lifecycle boundary: it must create the
orphan worktree before a worktree-local `.commit-lock` can be opened, so
simultaneous first initialization is not solved by `hive_commit` serialization.
See [first initialization](#hive-state-runtime-commit-serialization-is-process-tested-but-first-time-bootstrap-and-the-original-live-workload-remain-separate-gaps).

## Worktree Inspection Helpers

- `head_sha` returns `git rev-parse HEAD` for the configured root.
- `status_short` returns `git status --short` and raises `GitError` on failure.
- `current_branch` returns `git branch --show-current`, or `nil` for detached HEAD.
- `ancestor?(ancestor, descendant)` wraps `git merge-base --is-ancestor`, returning `true` / `false` for normal ancestry answers and raising `GitError` for command failures.

4-execute uses these helpers after the implementation spawn to verify the worktree stayed on the expected task branch, still descends from the execute baseline, is clean, and has produced an implementation commit before writing `EXECUTE_COMPLETE`.

## `run_git!` / `run_git_quiet`

`run_git!(*args)` invokes `Open3.capture3("git", *args)` and raises `Hive::GitError` on non-zero exit. `run_git_quiet` returns the tuple unchanged for cases where empty-error is expected (e.g. `git rm -rf .` on a directory with no tracked files).

## Tests

- `test/unit/git_ops_test.rb` — default-branch detection across remote/no-remote/no-commits scenarios; orphan worktree bootstrap; idempotent gitignore; commit skipping on empty diff; central lock coverage; and concurrent direct commits against one shared index.

## Backlinks

- [[commands/init]] · [[commands/run]] · [[commands/new]]
- [[modules/worktree]]
- [[state-model]]

## Known gaps

### Is `hive/state` reachable after `git gc`?

#### Source S28, lines 777–777: Open questions about the codebase

3. **Is `hive/state` reachable after `git gc`?** The plan recommends `git config --add gc.reflogExpire never refs/heads/hive/state`. This is documented in [[decisions]] ADR-003 but not enforced in `Init#call`.

### Local git index health affected the 2026-06-01 wiki refresh.

#### Source S28, lines 786–786: Open questions about the codebase

12. **Local git index health affected the 2026-06-01 wiki refresh.** `git status --short` failed with `fatal: unable to read 7afa1ea39e410defd0219acecd295e3108f5f93a`; `git ls-files -s` mapped that blob to `plugins/zoom/CONTRIBUTING.md`. The index also staged deletions for several wiki pages while the files still existed in the working tree. This refresh verified the committed docs change via `git show HEAD` and direct source reads, but a normal clean-tree check remains unresolved in this checkout.

### Hive-state runtime commit serialization is process-tested, but first-time bootstrap and the original live workload remain separate gaps.

#### Source S28, lines 866–866: Open questions about the codebase

46. **Hive-state runtime commit serialization is process-tested, but first-time bootstrap and the original live workload remain separate gaps.** `Hive::GitOps#hive_commit` now owns the project commit lock for every scoped staging/callback/diff/commit sequence, including display-name and Patrol Fix transition callers. The lock is same-thread reentrant for transactional callers that already hold it, rejects fork-inherited ownership by PID, and is process-tested for contention and `SIGKILL` release. A direct eight-process GitOps regression also pins one successful commit per child. `GitOps#hive_state_init` still creates the orphan worktree and bootstrap commit before a worktree-local `.commit-lock` can safely exist; simultaneous first initialization therefore needs a separate project-level lifecycle lock. The historical fragment for commit `bdd9a9fa` records the original 3-of-8 `hive new` failure, but this refresh still has no external Rails/system-worker artifact reproducing that exact Hive web workload after centralization.

### Conservative Git index-lock recovery (2026-09-07)

#### Source S75, lines 1675–1681: Conservative Git index-lock recovery (2026-09-07)

Automatic recovery requires successful process and open-file probes (`ps` and
`fuser`). Missing tools, inaccessible process state, any Git process, and
nonempty locks deliberately leave recovery to a later retry or operator.
This is not general recovery of interrupted Git operations; preserved lock
files may still require inspection on platforms without these probes.
