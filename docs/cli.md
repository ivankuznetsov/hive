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
| `hive review TARGET` | Run the autonomous review loop for a hive task. | `hive review <slug> --from 5-open-pr` |
| `hive review --pr PR` | Create or reuse an ad-hoc review task for an existing GitHub PR in the current registered repo. | `hive review --pr 197` |
| `hive artifacts TARGET` | Collect the reviewed task's release artifacts. | `hive artifacts <slug> --from 6-review` |
| `hive finalize TARGET` | Refresh PR body and mark the draft PR ready. | `hive finalize <slug> --from 7-artifacts` |
| `hive archive TARGET` | Move finalized work to `9-done/`. | `hive archive <slug> --from 8-finalize` |

The workflow verbs promote then run when the task is at the previous stage. If the task is already at the target stage, they only run that stage.

`hive review --pr PR` is the disambiguated ad-hoc path for reviewing a PR Hive did not open. `PR` may be `197`, `#197`, or a GitHub `/pull/197` URL. The command must run inside a repo already registered by `hive init` unless `--project NAME` selects one explicitly. It creates a synthetic `6-review/adhoc-review-pr-197/` task, fetches the PR head into a normal Hive worktree, then runs the same review stage. Re-running the command reuses that task; if another Hive task already owns the PR, Hive refuses to create a duplicate. The bare form `hive review 197` is unchanged and still resolves task id `197`.

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

The daemon can schedule patrol automatically through `patrol.trigger` (`continuous` by default — scans on a default-branch change or once per `poll_interval_sec`; `new_commits` restricts scanning to default-branch changes only) and `patrol.poll_interval_sec`, but the command is also useful for a one-off scan:

```bash
hive patrol my-project --json
hive patrol my-project --dry-run --json
```

The JSON envelope is `hive-patrol.v1` and includes mapped-feature, finding, fix, validation, PR, review handoff, skip, and `last_scanned_sha` counts. Durable patrol state is stored under `<project>/.hive-state/patrol/`.

Architecture patrol is the language-neutral post-merge discovery path. Fresh
projects enable its read-only discovery by default; headless setup can make the
choice before Hive writes state with `hive init --refactor-patrol` or
`hive init --no-refactor-patrol`. These flags do not enable auto-fixing or issue
filing. They are fresh-project selectors; an existing project rejects them
rather than silently ignoring the choice during a workflow rebind.

Durable architecture-patrol jobs have a non-mutating inspection surface:

```bash
hive refactor-patrol my-project --list
hive refactor-patrol my-project --list --limit 50 --cursor CURSOR
hive refactor-patrol my-project --show JOB_ID
hive refactor-patrol my-project --show JOB_ID --json
hive refactor-patrol my-project --show JOB_ID --full --json
```

List/show reads the authoritative job ledger without enqueueing, claiming,
replaying, or resuming work. JSON responses use
`hive-refactor-patrol-jobs.v1`. List pages default to 100 jobs and expose an
opaque continuation cursor bound to the first page's immutable intake-sequence
high-water, so later arrivals cannot change page membership. Show defaults to the latest 100 discovery attempts,
action claims, and publication attempts per history; `--limit 1..100` narrows
that bound, while `--full` explicitly opts into complete unbounded histories.
Legacy flat patch histories follow the same contract: bounded show retains the
active patch and reports omitted patch generations as truncated; `--full`
returns every flat patch and supersession receipt.

## Lower-Level Surface

| Command | Use it for |
|---|---|
| `hive run TARGET` | Dispatch the runner for the task's current stage. |
| `hive approve TARGET` | Move a task to the next stage or `--to <stage>`. |
| `hive markers clear FOLDER --name NAME` | Clear a recovery marker through the allowlisted path. |
| `hive rebase-status TARGET` | Inspect whether the next run would auto-rebase. |
| `hive refactor-patrol PROJECT --list\|--show JOB_ID [--limit N]` | Inspect durable architecture-patrol jobs without mutation; list pages use `--cursor`, while show accepts explicit `--full` history. |
| `hive migrate [PROJECT_PATH]` | Rename in-flight task folders from older stage layouts and backfill legacy task metadata. |
| `hive workflow new ID` | Scaffold a blank project workflow descriptor under `<hive_state_path>/workflows/`. |
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

Workflow verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`, `run`, `approve`), findings triage (`findings`, `accept-finding`, `reject-finding`), patrol (`patrol`), architecture-patrol job inspection (`refactor-patrol --list` / `--show`), diagnostics (`status`, `doctor`, `rebase-status`, `markers clear`, `metrics rollback-rate`), registry cleanup (`forget`, `prune`), workflow authoring (`workflow new`), `init`, and daemon control support `--json` where documented and emit typed envelopes. `hive init --json` emits a single `hive-init.v2` success payload with resolved answers and project metadata; architecture-patrol list/show emits `hive-refactor-patrol-jobs.v1`. Workflow verbs emit a `hive-stage-action` envelope; `hive workflow new --json` emits an unversioned success/error document. Schema files live under [schemas/](../schemas/), and [wiki/cli.md](../wiki/cli.md) lists the contract details. `hive tui` rejects `--json`; legacy or one-shot utilities (`version`, `tree`, `new`, `migrate`) are still text-only.

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
