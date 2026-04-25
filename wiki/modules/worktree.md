---
title: Hive::Worktree
type: module
source: lib/hive/worktree.rb
created: 2026-04-25
updated: 2026-04-25
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
#write_pointer!(task_folder, branch_name) → writes worktree.yml
```

Class methods:

```ruby
Hive::Worktree.read_pointer(task_folder) → Hash | nil
Hive::Worktree.validate_pointer_path(path, expected_root) → expanded_path | raises
```

## `worktree_root` resolution

If passed explicitly, that's used. Otherwise:

1. `cfg["worktree_root"]` from the project's `.hive-state/config.yml`.
2. Fallback: `~/Dev/<project_name>.worktrees`.

`File.expand_path`-ed so `~` works.

## `create!(branch_name, default_branch:)`

1. `mkdir -p` the parent of `path`.
2. Probe `git show-ref --verify refs/heads/<branch_name>`:
   - If it exists, run `git worktree add <path> <branch_name>` (attach to existing branch).
   - If not, run `git worktree add <path> -b <branch_name> <default_branch>` (create new branch off default).
3. On non-zero exit, raise `Hive::WorktreeError` with the captured stderr.

This handles re-attaching to a previously-created branch (e.g. after manually deleting a worktree) without losing history.

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
```

`read_pointer` parses with `YAML.safe_load` and validates the result is a Hash; raises `WorktreeError` otherwise.

## Path-prefix validation

`validate_pointer_path(path, expected_root)`:

1. `File.expand_path` both.
2. Require `path == expected_root` OR `path.start_with?(expected_root + File::SEPARATOR)`.
3. Otherwise raise `WorktreeError` with both paths.

This prevents an agent (with Write access to `worktree.yml`) from setting `path: ../../etc/passwd` and then having a later `Worktree#remove!` walk into a path-traversal attack.

## Used by

- `Stages::Execute#run_init_pass` — creates the worktree, writes the pointer, validates the prefix.
- `Stages::Execute#run_iteration_pass` — re-reads the pointer, re-validates.
- `Stages::Pr#run!` — reads pointer for the worktree path; `git push` runs there.
- `Stages::Done#run!` — reads pointer to print cleanup instructions.

## Tests

- `test/unit/worktree_test.rb` — create attach-vs-new branch, remove, exists?, pointer round-trip, prefix-validation rejection.

## Backlinks

- [[modules/git_ops]]
- [[stages/execute]] · [[stages/pr]] · [[stages/done]]
- [[state-model]]
