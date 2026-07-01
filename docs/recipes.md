# Recipes

These recipes are meant to be copied into real project work. They use the current nine-stage workflow.

## Xbookmark End-To-End

The xbookmark dogfood task started from this idea (typo `conenct` preserved from the original):

```text
I want to create a service that will conenct to my X (twitter) account and collect all the bookmarks...
```

It finished as [xbookmark PR #1](https://github.com/ivankuznetsov/xbookmark/pull/1). The replay transcript is committed at [docs/assets/xbookmark-walkthrough.txt](assets/xbookmark-walkthrough.txt), and a mid-run state tree (the task paused in `3-plan/`) is at [docs/assets/xbookmark-state-tree.txt](assets/xbookmark-state-tree.txt).

The workflow shape was:

```bash
cd ~/Dev/xbookmark
hive init .
hive new xbookmark "I want to create a service that will connect to my X account..."
hive brainstorm i-want-to-create-a-260504-1253
hive plan i-want-to-create-a-260504-1253
hive develop i-want-to-create-a-260504-1253
hive open-pr i-want-to-create-a-260504-1253
hive review i-want-to-create-a-260504-1253
hive artifacts i-want-to-create-a-260504-1253
hive finalize i-want-to-create-a-260504-1253
hive archive i-want-to-create-a-260504-1253
```

The output artefacts tell the story: `plan.md` captured the implementation units, `worktree.yml` pointed at `/home/asterio/Dev/xbookmark.worktrees/i-want-to-create-a-260504-1253`, `reviews/` held four review passes, and `pr.md` recorded `https://github.com/ivankuznetsov/xbookmark/pull/1`.

## Drive Multiple Projects

Register each project once:

```bash
cd ~/Dev/writero
hive init .
cd ~/Dev/xbookmark
hive init .
cd ~/Dev/screenote
hive init .
```

Then use the global view:

```bash
hive status
hive status --json
```

For automation, enroll projects and do a dry run before live dispatch:

```bash
hive daemon enable --all
hive daemon start --dry-run --detach
hive daemon tail
```

When the dry-run dispatches look right:

```bash
hive daemon stop
hive daemon start --detach
```

## Recover From REVIEW_STALE

`REVIEW_STALE` means the review stage hit `review.max_passes` or `review.max_wall_clock_sec`. Start by inspecting the highest pass:

```bash
cd ~/Dev/your-project
hive status
$EDITOR .hive-state/stages/6-review/<slug>/reviews/escalations-<NN>.md
```

Tick findings you want fixed or trim stale findings that no longer apply. Then clear the marker through the typed command and re-run review:

```bash
hive markers clear <slug> --name REVIEW_STALE --project your-project
hive review <slug> --from 6-review
```

`--from <stage>` is the retry-safety assertion explained in [docs/architecture.md#markers-and-idempotency](architecture.md#markers-and-idempotency); it is optional when you re-run a stage by hand.

If CI caused the stop, swap the marker name. The same shape works for the other terminal review markers:

```bash
hive markers clear <slug> --name REVIEW_CI_STALE --project your-project
hive review <slug> --from 6-review
```

Use `--name REVIEW_ERROR` when the runner recorded a phase error.

### Recover a tmux review-fix Stop-hook timeout

For affected versions, a tmux-launched review-fix agent can finish, write
artifacts, and even commit, but still leave `REVIEW_ERROR phase=fix
reason=fix_failed` because Claude's interactive Stop hook did not write
`.done` / `result.json`. Hive now accepts that case only when it can prove
completion from on-disk evidence and emits `claude_completion_fallback`.

For already-stuck tasks such as task 58 / PR #622, task 287 / PR #623, and
task 288 / PR #624, do not clear the marker blindly. First verify all of
these:

- `reviews/escalations-<NN>.md` exists and has no unresolved `[ ]` items;
- the fix pass produced `reviews/fix-success-<NN>.md`, or the branch has a
  fix commit after the pass began, or the reviewed files contain a checked
  `RESOLVED/NO-FIX:` line explaining why no code change was needed;
- the worktree is readable and `git status --porcelain` is clean;
- there is no provider-limit, missing-output, protected-file tamper, or
  unresolved escalation marker explaining a real failure.

When the evidence is present, clear only the matching fix failure and rerun
review:

```bash
hive markers clear <FOLDER> --name REVIEW_ERROR --match-attr phase=fix,reason=fix_failed
hive run <FOLDER>
```

If any evidence is missing, inspect the task manually and rerun without
clearing only after you understand the failure. `claude.mode: headless`
remains the recommended workaround for affected versions and service hosts;
this fix does not rewrite or revert local operator config.

## Recover From EXECUTE_STALE

`EXECUTE_STALE` means execute exhausted its retry budget without leaving a clean implementation commit on the feature worktree. Start by reading what the agent produced:

```bash
cd ~/Dev/your-project
hive status
$EDITOR .hive-state/stages/4-execute/<slug>/task.md
```

Fix the underlying issue (apply edits in the feature worktree if needed), then clear the marker and re-run execute:

```bash
hive markers clear <slug> --name EXECUTE_STALE --project your-project
hive develop <slug> --from 4-execute
```

## Hand-Edit Inside A Stage

Hive expects human edits. A typical plan loop:

```bash
hive plan <slug> --from 2-brainstorm
$EDITOR .hive-state/stages/3-plan/<slug>/plan.md
hive plan <slug> --from 3-plan
```

The same pattern works for brainstorm answers and review escalation files. The file is the interface; the command validates markers and records the state commit.
