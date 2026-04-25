---
title: 7-done stage
type: stage
source: lib/hive/stages/done.rb
created: 2026-04-25
updated: 2026-04-25
tags: [stage, done, archive]
---

**TLDR**: Archive stage. `hive run` here does not spawn an agent; it prints the manual cleanup commands (`git worktree remove`, `git branch -d`) and stamps `<!-- COMPLETE -->` on the state file.

## State file

Reuses `task.md` from `4-execute/`. Falls back to creating an empty `task.md` if missing (e.g. task somehow skipped execute).

## Behaviour of `hive run`

`Stages::Done.run!` (`lib/hive/stages/done.rb:8`):

1. `FileUtils.touch(task.state_file)` if absent.
2. Read `worktree.yml` if present.
3. If pointer present, print:
   ```
   Task <slug> marked done. To clean up:
     cd <project_root>
     git worktree remove <worktree-path>
     git branch -d <branch>
   (Use -D / --force if the branch was squash-merged.)
   ```
   Otherwise print `"Task <slug> archived. No worktree pointer; nothing to clean up."`
4. Set `<!-- COMPLETE -->` marker.
5. Return `{commit: "archived", status: :complete}`.

## Why cleanup is manual

The MVP intentionally does not run `git worktree remove` automatically because squash-merged branches require `-D`/`--force` and the user might still have unpushed local commits in the feature branch. Auto-cleanup is deferred to Phase 3 (per the plan's "Deferred to Follow-Up Work").

## Backlinks

- [[stages/pr]] · [[stages/execute]]
- [[modules/worktree]] · [[modules/markers]]
- [[state-model]]
