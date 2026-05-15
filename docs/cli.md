# CLI

This page documents the command surface exposed by `bin/hive` in this checkout. For the full API contract, see [wiki/cli.md](../wiki/cli.md).

## Day-To-Day Workflow

| Command | Use it for | Example |
|---|---|---|
| `hive status` | See active tasks grouped by next action. | `hive status` |
| `hive new PROJECT TEXT` | Capture an idea in `1-inbox/`. | `hive new xbookmark "save bookmarks"` |
| `hive brainstorm TARGET` | Promote inbox to brainstorm or re-run brainstorm. | `hive brainstorm save-bookmarks-260515-abcd` |
| `hive plan TARGET` | Promote completed brainstorm to plan or re-run plan. | `hive plan save-bookmarks-260515-abcd --from 2-brainstorm` |
| `hive develop TARGET` | Promote completed plan to execute or re-run execute. | `hive develop save-bookmarks-260515-abcd --from 3-plan` |
| `hive open-pr TARGET` | Promote completed execute to draft PR creation. | `hive open-pr save-bookmarks-260515-abcd --from 4-execute` |
| `hive review TARGET` | Run the autonomous review loop. | `hive review save-bookmarks-260515-abcd --from 5-open-pr` |
| `hive finalize TARGET` | Refresh PR body and mark the draft PR ready. | `hive finalize save-bookmarks-260515-abcd --from 6-review` |
| `hive archive TARGET` | Move finalized work to `8-done/`. | `hive archive save-bookmarks-260515-abcd --from 7-finalize` |

The workflow verbs promote then run when the task is at the previous stage. If the task is already at the target stage, they only run that stage.

## Findings Triage

| Command | Use it for |
|---|---|
| `hive findings TARGET` | List GFM checkbox findings from the latest review pass. |
| `hive accept-finding TARGET ID...` | Tick findings to feed them into the next fix pass. |
| `hive reject-finding TARGET ID...` | Untick findings so they are not fixed. |

Selectors can be explicit IDs, `--severity high`, or `--all`.

```bash
hive findings <slug>
hive accept-finding <slug> 1 3
hive reject-finding <slug> --severity nit
```

## Lower-Level Surface

| Command | Use it for |
|---|---|
| `hive run TARGET` | Dispatch the runner for the task's current stage. |
| `hive approve TARGET` | Move a task to the next stage or `--to <stage>`. |
| `hive markers clear FOLDER --name NAME` | Clear a recovery marker through the allowlisted path. |
| `hive rebase-status TARGET` | Inspect whether the next run would auto-rebase. |
| `hive migrate [PROJECT_PATH]` | Rename in-flight task folders from older stage layouts. |
| `hive tree` | Print the Thor command tree. |

Use these when building scripts, recovering a task, or checking idempotency.

## Daemon

The daemon is optional and per-project. It polls `hive status --json`, dispatches workflow verbs for tasks that can advance, stops at human-input gates, and auto-archives finalized tasks after GitHub reports the PR merged.

```bash
hive daemon enable <project>
hive daemon enable --all
hive daemon start --dry-run --detach
hive daemon status
hive daemon tail
hive daemon stop
hive daemon disable <project>
```

Read [wiki/operating.md](../wiki/operating.md) before running it live.

## Bot And TUI

`hive tui` opens the terminal dashboard for humans. `hive bot start|stop|status|reload|tail` runs the Telegram surface for human-input gates. Both read the same state as the CLI; the TUI intentionally rejects `--json`.

## Diagnostics

| Command | Use it for |
|---|---|
| `hive doctor` | Verify configured stage and reviewer skills. |
| `hive doctor --json` | Emit the same checks in a machine-readable envelope. |
| `hive version` or `hive --version` | Print the Hive version. |
| `hive forget NAME` | Remove one project from the global registry. |
| `hive prune` | Remove registry rows whose project path is gone. |
| `hive metrics rollback-rate` | Report the fraction of fix-agent commits later reverted. |

## JSON Output

Every machine-callable command supports `--json` and emits a single typed envelope with `ok: true` on success or `ok: false` on failure. `hive tui` is the only surface that rejects `--json`. Workflow verbs emit a `hive-stage-action` envelope. Schema files live under [schemas/](../schemas/), and [wiki/cli.md](../wiki/cli.md) lists the contract details.

## Exit Codes

| Code | Meaning |
|---:|---|
| 0 | Success. |
| 1 | Generic failure. |
| 2 | Already initialized. |
| 3 | Task is in an error marker state. |
| 4 | Wrong stage. |
| 64 | Usage error. |
| 65 | `hive doctor`: at least one configured skill is missing. |
| 70 | Software, git, worktree, agent, or stage failure. |
| 75 | Temporary failure, usually lock contention. |
| 78 | Config error. |
