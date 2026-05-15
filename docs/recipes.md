# Recipes

These recipes are meant to be copied into real project work. They use the current eight-stage workflow.

## Xbookmark End-To-End

The xbookmark dogfood task started from this idea:

```text
I want to create a service that will conenct to my X (twitter) account and collect all the bookmarks...
```

It finished as [xbookmark PR #1](https://github.com/ivankuznetsov/xbookmark/pull/1). The replay transcript is committed at [docs/assets/xbookmark-walkthrough.txt](assets/xbookmark-walkthrough.txt), and the finished state tree is at [docs/assets/xbookmark-state-tree.txt](assets/xbookmark-state-tree.txt).

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

If CI caused the stop, use `REVIEW_CI_STALE`. If the runner recorded a phase error, use `REVIEW_ERROR`.

## Hand-Edit Inside A Stage

Hive expects human edits. A typical plan loop:

```bash
hive plan <slug> --from 2-brainstorm
$EDITOR .hive-state/stages/3-plan/<slug>/plan.md
hive plan <slug> --from 3-plan
```

The same pattern works for brainstorm answers and review escalation files. The file is the interface; the command validates markers and records the state commit.
