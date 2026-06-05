# CLI

This page documents the command surface exposed by `bin/hive` in this checkout. For the full API contract, see [wiki/cli.md](../wiki/cli.md).

## Day-To-Day Workflow

| Command | Use it for | Example |
|---|---|---|
| `hive status` | See active tasks grouped by next action. | `hive status` |
| `hive new PROJECT TEXT` | Capture an idea in `1-inbox/`. | `hive new xbookmark "save bookmarks"` |
| `hive brainstorm TARGET` | Promote inbox to brainstorm or re-run brainstorm. | `hive brainstorm <slug>` |
| `hive plan TARGET` | Promote completed brainstorm to plan or re-run plan. | `hive plan <slug> --from 2-brainstorm` |
| `hive develop TARGET` | Promote completed plan to execute or re-run execute. | `hive develop <slug> --from 3-plan` |
| `hive open-pr TARGET` | Promote completed execute to draft PR creation. | `hive open-pr <slug> --from 4-execute` |
| `hive review TARGET` | Run the autonomous review loop. | `hive review <slug> --from 5-open-pr` |
| `hive artifacts TARGET` | Collect the reviewed task's release artifacts. | `hive artifacts <slug> --from 6-review` |
| `hive finalize TARGET` | Refresh PR body and mark the draft PR ready. | `hive finalize <slug> --from 7-artifacts` |
| `hive archive TARGET` | Move finalized work to `9-done/`. | `hive archive <slug> --from 8-finalize` |

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

## Patrol

`hive patrol PROJECT [--dry-run] [--json]` runs one repository patrol cycle for a registered project whose `.hive-state/config.yml` has `patrol.enabled: true`. The cycle maps semantic feature slices, reviews each slice with the configured patrol agent, attempts fixes above the confidence gate in isolated worktrees, runs configured validation commands, and opens PRs only for validated fixes. Successful PRs are handed to the standard `6-review` flow by default as visible `Patrol: ...` tasks; set `patrol.review_prs: false` to keep the old PR-only behavior.

The daemon can schedule patrol automatically through `patrol.trigger` (`new_commits` by default) and `patrol.poll_interval_sec`, but the command is also useful for a one-off scan:

```bash
hive patrol my-project --json
hive patrol my-project --dry-run --json
```

The JSON envelope is `hive-patrol.v1` and includes mapped-feature, finding, fix, validation, PR, review handoff, skip, and `last_scanned_sha` counts. Durable patrol state is stored under `<project>/.hive-state/patrol/`.

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

The daemon process is global user infrastructure; dispatch is per-project. Install-time setup runs `hive daemon install` so the service survives login/reboot, while `hive init` or `hive daemon enable` decides which projects it may touch. It polls `hive status --json`, dispatches workflow verbs for tasks that can advance, stops at human-input gates, and auto-archives finalized tasks after GitHub reports the finalize-stage PR merged.
When a project also has `patrol.enabled: true`, the daemon's patrol scheduler dispatches `hive patrol <project> --json` on the configured slow cadence through the same project-enabled and concurrency gates as other daemon children.

```bash
hive daemon install
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

`hive tui` opens the terminal dashboard for humans. `hive bot start|stop|status|reload|tail|install` runs the Telegram surface for human-input gates. Both read the same state as the CLI; the TUI intentionally rejects `--json`. `hive bot install [--force] [--json]` installs and enables a per-user autostart service for the bot (systemd-user on Linux, launchd on macOS) so it survives reboot/login — opt-in, mirroring `hive daemon install`; the token comes from `~/.config/hive/.env`, and `hive uninstall` removes the service.

## Diagnostics

| Command | Use it for |
|---|---|
| `hive doctor` | Verify configured stage and reviewer skills. |
| `hive doctor --json` | Emit the same checks in a machine-readable envelope. |
| `hive version` or `hive --version` | Print the Hive version. |
| `hive forget NAME [--if-exists]` | Remove one project from the global registry; `--if-exists` makes already-absent entries exit 0. |
| `hive prune` | Remove registry rows whose project path is gone. |
| `hive metrics rollback-rate` | Report the fraction of fix-agent commits later reverted. |

## JSON Output

Workflow verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`, `run`, `approve`), findings triage (`findings`, `accept-finding`, `reject-finding`), patrol (`patrol`), diagnostics (`status`, `doctor`, `rebase-status`, `markers clear`, `metrics rollback-rate`), registry cleanup (`forget`, `prune`), `init`, and daemon control support `--json` where documented and emit typed envelopes. `hive init --json` emits a single `hive-init.v1` success payload with resolved answers and project metadata; its precondition failures keep the legacy stderr + exit-code contract. Workflow verbs emit a `hive-stage-action` envelope. Schema files live under [schemas/](../schemas/), and [wiki/cli.md](../wiki/cli.md) lists the contract details. `hive tui` rejects `--json`; legacy or one-shot utilities (`version`, `tree`, `new`, `migrate`) are still text-only.

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
