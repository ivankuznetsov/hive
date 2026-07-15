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

## Lower-Level Surface

| Command | Use it for |
|---|---|
| `hive run TARGET` | Dispatch the runner for the task's current stage. |
| `hive approve TARGET` | Move a task to the next stage or `--to <stage>`. |
| `hive markers clear FOLDER --name NAME` | Clear a recovery marker through the allowlisted path. |
| `hive rebase-status TARGET` | Inspect whether the next run would auto-rebase. |
| `hive migrate [PROJECT_PATH]` | Rename in-flight task folders from older stage layouts and backfill legacy task metadata. |
| `hive workflow new ID` | Scaffold a blank project workflow descriptor under `<hive_state_path>/workflows/`. |
| `hive workflow install honeycomb/NAME[@SELECTOR]` | Preview and install an immutable workflow package from the public honeycomb registry. |
| `hive workflow list [--remote\|--outdated]` | List managed packages locally, or explicitly refresh the public catalog. |
| `hive workflow update NAME[@SELECTOR]\|--all` | Preview package, permission, and instruction changes before one transaction. |
| `hive workflow remove NAME` | Remove a managed package after ownership and integrity checks. |
| `hive tree` | Print the Thor command tree. |

Use these when building scripts, recovering a task, or checking idempotency.

### Honeycomb package management

Honeycomb references use `honeycomb/<name>`, optionally followed by an exact
SemVer, full/unique catalog SHA, or complete package digest. Hive resolves the
selection through the single public `github.com/ivankuznetsov/honeycomb`
registry and records the immutable commit, digest, selector intent, inventory,
and derived security report in `.hive-state/workflows/.honeycomb.lock`.

```bash
hive workflow install honeycomb/release-notes
hive workflow install honeycomb/release-notes@1.2.0 --yes
hive workflow list
hive workflow list --remote
hive workflow list --outdated
hive workflow update release-notes
hive workflow update --all --yes
hive workflow remove release-notes
```

Plain `list` is network-free and reports update availability as `unknown` when
there is no cached catalog. `--remote` and `--outdated` explicitly refresh the
catalog and are mutually exclusive. Mutating commands show their complete
preview before confirmation. In non-interactive use they require `--yes`;
`--force` permits a dirty managed install or an unmanaged local collision but
never supplies approval. SHA/digest-origin installs remain pinned during an
untargeted update. Update previews identify permission escalation and include
the full unified diff of every changed instruction file.

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

Workflow verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`, `run`, `approve`), findings triage (`findings`, `accept-finding`, `reject-finding`), patrol (`patrol`), diagnostics (`status`, `doctor`, `rebase-status`, `markers clear`, `metrics rollback-rate`), registry cleanup (`forget`, `prune`), workflow authoring/package management (`workflow new|install|list|update|remove`), `init`, and daemon control support `--json` where documented and emit typed envelopes. Honeycomb operations emit the versioned `hive-workflow-{install,list,update,remove}.v1` contracts. `hive init --json` emits a single `hive-init.v1` success payload with resolved answers and project metadata; its precondition failures keep the legacy stderr + exit-code contract. Workflow verbs emit a `hive-stage-action` envelope; `hive workflow new --json` emits an unversioned success/error document. Schema files live under [schemas/](../schemas/), and [wiki/cli.md](../wiki/cli.md) lists the contract details. `hive tui` rejects `--json`; legacy or one-shot utilities (`version`, `tree`, `new`, `migrate`) are still text-only.

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
