---
title: CLI Surface
type: api
source: bin/hive, bin/hv, lib/hive/cli.rb
created: 2026-04-25
updated: 2026-06-30
tags: [cli, api]
---

**TLDR**: Hive exposes a Thor-based CLI through `hive`, plus an `hv` fallback entrypoint for hosts where Apache Hive shadows the `hive` name. The human workflow is `hive status` followed by stage verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive <target>`) that move-or-run tasks by slug; no-target `hive archive` lists `9-done` tasks. `hive review --pr <n>` is the disambiguated ad-hoc entry point for reviewing an existing GitHub PR that Hive did not open while still using the normal `6-review` runner. `run`, `approve`, `findings`, `markers`, `metrics`, `connect screenote`, `disconnect screenote`, `bench submit`, `digest`, and `pairing` are the lower-level agent/script, auth, contribution, or reporting surfaces. `hive tui` is the human-only dashboard over `hive status`; `hive daemon` auto-advances safe rows; `hive babysit` runs the experimental PR babysitter; `hive bot` runs the Telegram mobile surface for human-input gates, and `hive pairing` approves first-contact Telegram users. `status`, `run`, `approve`, `findings`, `markers`, `metrics`, Screenote connect/disconnect, `bench submit`, `digest`, `pairing`, daemon lifecycle/install/enrollment/queue, and bot lifecycle support `--json` where documented. Process exit codes are stable per `Hive::ExitCodes` so wrappers can branch deterministically.

## Entry point

`bin/hive` is a thin runner that loads `lib/hive` and calls `Hive::CLI.start(ARGV)`, catching `Hive::Error` to render `hive: <message>` to stderr with the error's `exit_code` (default `ExitCodes::GENERIC = 1`).

Before Thor dispatch, `bin/hive` handles two wrapper-level cases itself:
top-level `--version` / `-v` prints `Hive::VERSION`, and command-local
`--help` / `-h` is rewritten to `help <cmd>`. The help rewrite preserves any
leading dash-prefixed arguments that appear before the subcommand, then drops
the command-local arguments after the subcommand so calls such as
`hive approve --from 2-brainstorm --help` print the `approve` usage text
instead of validating `--from` or consuming `--help` as a positional target.
Leading wrapper-level JSON options are normalized before dispatch for the same
reason. Accepted boolean forms match Thor's exact grammar: bare `--json`, exact
truthy assignments (`--json=true`/`TRUE`/`t`/`T`), and false forms
(`--no-json`, `--skip-json`, `--json=false`/`FALSE`/`f`/`F`). Unsupported
assignments such as `--json=1` or `--json=yes` exit with usage before their
values can be treated as a command argument or task target. `hive new` has a
special lift-and-rebuild path: standalone allow-listed options are lifted from
before the project, between project and text, or after text, then the remaining
`PROJECT TEXT...` tail is protected with `--` so Thor does not parse literal
task text as options. The allow-list is `--workflow`/`--depends-on` (whose value
is the next token, but only when that token exists and is not option-like — a
trailing or value-less `--workflow`/`--depends-on` stays literal text rather than
swallowing PROJECT), their `--workflow=VALUE`/`--depends-on=VALUE` `name=`-prefix
forms, and JSON booleans lifted only in their exact accepted forms (`--json`,
`--json=true`, `--no-json`, etc.). Non-allow-listed tokens such
as `--help`, unsupported-looking `--json=...` assignments after `PROJECT`,
unrecognized `--foo`, and quoted strings containing `--workflow` remain task
text. When the wrapper itself catches a usage error, JSON-vs-prose mode is
decided from the last recognized JSON boolean flag in argv, so a trailing false
form such as `--no-json` or `--json=false` overrides an earlier `--json`.
Before any wrapper rewrite or Thor dispatch, every `ARGV` entry must have valid
encoding. Invalid-byte arguments raise through the same usage-error path as
malformed wrapper options, so JSON callers still receive the command-specific
error envelope instead of a Ruby/Thor backtrace.

When a JSON request fails in Thor before the command object runs, `bin/hive`
uses `JSON_USAGE_ERROR_CONTRACTS` to keep the error shaped like the requested
surface. Missing-target or missing-project usage errors for `run`,
`rebase-status`, workflow verbs, `approve`, `drop`, `findings`,
`accept-finding`, `reject-finding`, `markers`, and `patrol` emit a
command-specific JSON failure on stdout before the human `hive:` stderr line.
Schemas registered in `Hive::Schemas::SCHEMA_VERSIONS` use
`Hive::Schemas::ErrorEnvelope` and include `schema_version`; the older
`hive-rebase-status` inspector keeps its unversioned sibling shape. Workflow
verbs include the `verb` extra (`pr` maps to `open-pr`), finding toggles include
`operation`, and patrol's pre-dispatch usage failure uses the `hive-patrol`
schema with `error_kind: "error"`.

`bin/hv` is a bash fallback launcher for Apache Hive name collisions. It deliberately avoids `command -v hive`; instead it probes only `HIVE_BIN_OVERRIDE`, `${XDG_BIN_HOME:-$HOME/.local/bin}/hive`, `${HOMEBREW_PREFIX:-/opt/homebrew}/bin/hive`, and `/usr/local/bin/hive`, skipping a target that resolves back to itself. It does not implicitly exec `/usr/bin/hive` or `/opt/hive/bin/hive`, because those paths may be Apache Hive installs. If no candidate is executable it exits `127` and tells the operator to set `HIVE_BIN_OVERRIDE` or install through the documented channels. `bin/hv` remains in the gem payload for channel installers to copy/read, but it is not listed in `spec.executables`; RubyGems would otherwise generate a Ruby binstub for this bash launcher. See [[operating]] for channel-level `hv` behavior.

## Command table

| Command | Synopsis | Routes to | Page |
|---------|----------|-----------|------|
| `hive init [PROJECT_PATH] [--json]` | Bootstrap `.hive-state` orphan branch + worktree plus managed llm-wiki context in a git project; `--json` emits `hive-init.v1` on success | `Hive::Commands::Init` | [[commands/init]] |
| `hive new PROJECT TEXT...` | Create a task in `1-inbox/` of a registered project, writing `idea.md` plus `meta.yml`; stdout prints a next-step hint that uses the numeric task id when allocation succeeds | `Hive::Commands::New` | [[commands/new]] |
| `hive workflow new ID [--json]` | Scaffold a blank per-project workflow descriptor plus placeholder instruction under `<hive_state_path>/workflows/` | `Hive::Commands::Workflow` | [[commands/workflow]] |
| `hive generate-name TARGET [--project NAME] [--stage STAGE]` | Generate and persist a short display title for a task; target resolves by path, slug, or numeric id | `Hive::Commands::GenerateName` | [[commands/generate-name]] |
| `hive status [--diagnose SLUG [--write [--force]] [--project NAME] [--stage STAGE]]` | Action-grouped task list across registered projects. With `--diagnose <slug>`, prints the bounded diagnostic for one task (schema `hive-status-diagnose`). Add `--write` to spawn the configured execute `AgentProfile` and atomically write `<task>/diagnostics/red-status.md` (no lock, no marker mutation; `--force` bypasses the `marker_signature` idempotency short-circuit; green rows are rejected). | `Hive::Commands::Status` (delegates write path to `Hive::DiagnosisAgent`) | [[commands/status]] |
| `hive tui` | Live, keystroke-driven Charm bubbletea + lipgloss dashboard over `hive status` (human-only; rejects `--json`) | `Hive::Tui` | [[commands/tui]] |
| `hive daemon SUBCOMMAND` | Auto-advance pipeline dispatcher. Subcommands: `start` / `stop` / `status` / `reload` / `tail` for the daemon process; `install [--force]` to (re)write the platform-native unit file (preserves operator hand-edits without `--force`; rotates the prior file to `<path>.bak-<ts>` and restarts the daemon with `--force`); `enable PROJECT \| --all` and `disable` for per-project enrollment (atomic write to `<project>/.hive-state/config.yml`); `queue [list \| show <id> \| prune]` for read-only inspection of the dispatch-request queue the bot writes and the daemon consumes (runs in the CLI process, no daemon contact; `--json` emits `hive-daemon-queue.v1`). Polls `hive status --json` and fires workflow verbs on tasks ready to advance; auto-archives 8-finalize after PR merge. The dispatcher also runs `Hive::Daemon::StaleAgentHealer` on every tick: it rewrites stale `AGENT_WORKING` markers to `ERROR reason=agent_died` / `reason=agent_orphaned` (grace = `daemon.agent_marker_grace_sec`, default 300s), and clears selected no-live-lock terminal `ERROR` markers (`8-finalize` `reason=unpushed_commits`, plus `7-artifacts` / `8-finalize` `reason=tmux_session_terminated` or `reason=agent_orphaned`) with marker-id guards and bounded retry budgets. Daemon autostart is installed globally via `hive daemon install`; new projects opt in to dispatch at `hive init` (default Y), and existing ones via `hive daemon enable`. See [[operating]] for the install + systemd/launchd setup guide. | `Hive::Commands::Daemon` | [[commands/daemon]] |
| `hive babysit SUBCOMMAND [PROJECT]` | Experimental PR babysitter. Subcommands: `start` / `stop` / `restart` / `status` / `reload` / `tail`, plus `--once PROJECT` or `--once --all` for one-shot passes. Separate from `hive daemon`; polls open GitHub PRs for projects with `babysitter.enabled: true`, skips ignored labels, spawns the configured development agent in `.hive-state/babysitter/worktrees/<pr>/`, and labels/comments only on give-up. `reload` refreshes config/log settings but not Ruby code; `status` recommends `hive babysit restart --detach` when the running PID predates the current source checkout. | `Hive::Commands::Babysit` | [[commands/babysit]] |
| `hive bot SUBCOMMAND` | Telegram bot lifecycle. Subcommands: `start` / `stop` / `status` / `reload` / `tail`. Long-polls Telegram, authenticates by `bot.chat_id_allowlist`, notifies on waiting/recovery gates, and dispatches existing `hive` commands from inline buttons. | `Hive::Commands::Bot` | [[commands/bot]] |
| `hive pairing SUBCOMMAND` | Telegram pairing approval. `list` shows pending first-contact `/start` codes; `approve telegram <CODE>` appends the chat id to `bot.chat_id_allowlist`, reloads the bot when running, and queues the approved DM. | `Hive::Commands::Pairing` | [[commands/pairing]] |
| `hive brainstorm TARGET [--from STAGE]` | Start or re-run brainstorm by slug/path | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive plan TARGET [--from STAGE]` | Promote completed brainstorm to plan, or re-run plan | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive develop TARGET [--from STAGE]` | Promote completed plan to execute, or re-run execute | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive open-pr TARGET [--from STAGE]` | Promote completed execute to draft PR creation, or re-run open-pr | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive review TARGET [--from STAGE]` | Promote opened draft PR to review, or re-run review. A bare numeric target remains a task id. | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive review --pr PR [--project NAME] [--json]` | Create or reuse an ad-hoc `6-review/adhoc-review-pr-N/` task for a GitHub PR (`N`, `#N`, or `/pull/N` URL) in a registered project, then run review through the same StageAction path. | `Hive::Commands::AdhocReview` → `Hive::Commands::StageAction` | [[commands/stage_action]], [[stages/review]] |
| `hive artifacts TARGET [--from STAGE]` | Promote completed review to artifact collection, or re-run artifacts | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive finalize TARGET [--from STAGE]` | Promote completed artifacts to PR finalization, or re-run finalize | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive archive [TARGET] [--from STAGE]` | With no target, list every `9-done` task across registered projects through Status archive mode (`--json` returns a `hive-status` payload filtered to done rows). With a target, promote finalized PR to done, or re-run done. The internal `--recover-merged-error-reason` flag is reserved for daemon merge-watcher recovery of already-merged finalize error rows. | no target: `Hive::Commands::Status`; target: `Hive::Commands::StageAction` → approve/run | [[commands/status]], [[commands/stage_action]] |
| `hive connect screenote [--base-url URL] [--json]` | Run Screenote OAuth 2.1 auth-code + PKCE setup, pick a default Screenote project via MCP `list_projects`, and persist `screenote.json` for artifacts-stage MCP injection. | `Hive::Commands::Connect` | [[commands/screenote]] |
| `hive disconnect screenote [--json]` | Revoke the stored Screenote token when possible and clear `screenote.json`; no-op when already disconnected. | `Hive::Commands::Disconnect` | [[commands/screenote]] |
| `hive bench submit SLUG [--project NAME] [--json]` | Extract a completed `9-done` task into a hive-bench corpus entry and open a submission PR from the hive-bench checkout. Requires `HIVE_BENCH_PATH` or `~/Dev/hive-bench`, a GitHub `origin` remote for the source project, `worktree.yml`, `pr.md`, and a clean local secret-token preflight. | `Hive::Commands::BenchSubmit` | [[commands/bench-submit]] |
| `hive digest [--date YYYY-MM-DD] [--dry-run] [--json]` | Build the daily shipped digest for tasks that reached `9-done` on one local calendar date. Dry-run prints the rendered Telegram MarkdownV2 body; real delivery loads global digest/bot config, then sends through `Hive::Digest::Sender` and the bot Telegram client. The daemon can schedule this globally after local midnight when `digest.enabled: true`. | `Hive::Commands::Digest` → `Hive::Digest` | [[commands/digest]] |
| `hive run TARGET [--no-rebase]` | Lower-level dispatcher for a slug or task folder. `--no-rebase` skips the auto-rebase pre-step for one invocation (one-off override of `cfg.rebase.enabled`). | `Hive::Commands::Run` → stage runner | [[commands/run]] |
| `hive rebase-status TARGET` | Read-only inspector: reports whether the next `hive run` would attempt an auto-rebase, how many commits behind `origin/<default>` the worktree is, and which guard (if any) would short-circuit. Never mutates; never calls `git fetch`. | `Hive::Commands::RebaseStatus` | [[commands/rebase-status]] |
| `hive approve TARGET [--to STAGE] [--from STAGE]` | Move a task between stages + record a hive/state commit (agent-callable equivalent of shell `mv`; `--from` asserts current stage for retry idempotency) | `Hive::Commands::Approve` | [[commands/approve]] |
| `hive drop TARGET [--project NAME] [--from STAGE]` | Hard-delete an active task: kill its recorded agent, close draft PR best-effort, remove task folder(s), logs, worktree, branch, and locks, then commit an audit record. Refuses `9-done`. | `Hive::Commands::Drop` | [[commands/drop]] |
| `hive findings TARGET [--pass N] [--stage STAGE]` | List GFM-checkbox findings in `reviews/ce-review-NN.md` (latest by default) | `Hive::Commands::Findings` | [[commands/findings]] |
| `hive accept-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Tick `[x]` on review findings; selectors are unioned | `Hive::Commands::FindingToggle` (accept) | [[commands/findings]] |
| `hive reject-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Untick `[x]` on review findings | `Hive::Commands::FindingToggle` (reject) | [[commands/findings]] |
| `hive markers clear FOLDER --name <NAME> [--match-attr KEY=VALUE] [--project NAME] [--json]` | Remove a recovery marker (`REVIEW_STALE`, `REVIEW_CI_STALE`, `REVIEW_ERROR`, `EXECUTE_STALE`, `ERROR`) from a task's state file (atomic write + hive_commit). Terminal-success markers (`REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE`) are deliberately rejected — use `hive approve` instead. `--match-attr KEY=VALUE` refuses the clear unless the current marker carries the named attribute (exit 4 on mismatch); the `hive tui` auto-healer uses it to avoid erasing a real-failure marker that landed between observation and heal under cross-process concurrency. | `Hive::Commands::Markers` | [[commands/markers]] |
| `hive metrics SUBCOMMAND [--days N] [--project NAME] [--json]` | Compute project-wide metrics. Currently one subcommand: `rollback-rate` walks `git log --all` and reports the fraction of fix-commits (those carrying `Hive-Fix-Pass` trailer) that were later reverted, broken down by `Hive-Triage-Bias` and `Hive-Fix-Phase`. | `Hive::Commands::Metrics` → `Hive::Metrics` | — |
| `hive update` | Re-run the install channel that originally placed the binary (xdg/homebrew/aur). Reads channel from `~/.local/state/hive/install-channel` (or `Hive::InstallChannel.detect`) and re-invokes the matching installer; refuses to act when the channel is unknown. See `lib/hive/commands/update.rb`. | `Hive::Commands::Update` | — |
| `hive uninstall [--purge]` | Remove user-scoped hive runtime: stop daemon/bot, remove launchd/systemd units, drop xdg-installed binary, prune `~/.local/state/hive`. `--purge` also removes the global registry at `~/.config/hive/config.yml` (or `HIVE_HOME/config.yml` when overridden). Never touches per-project `.hive-state/` working trees. See `lib/hive/commands/uninstall.rb`. | `Hive::Commands::Uninstall` | — |
| `hive migrate [PROJECT_PATH]` | One-shot rename of in-flight task folders from the pre-open-pr stage layout to the current 9-stage layout. | `Hive::CLI#migrate` | — |
| `hive doctor [--json]` | Walk `brainstorm` + `plan` stage configs and every `review.reviewers[]` entry, asking each agent profile to verify its configured skill resolves to an installed slash-command / SKILL.md on disk. When `claude.mode == "tmux"` also adds a `kind: "dependency"` row checking tmux availability + minimum version; legacy `brainstorm.runtime` emits an advisory warning. Also runs non-fatally at the tail of `hive init`. Exits 0 / 65 / 78. | `Hive::Commands::Doctor` | [[commands/doctor]] |
| `hive forget NAME [--if-exists] [--json]` | Drop one named entry from the global registry (`~/.config/hive/config.yml`, or `HIVE_HOME/config.yml` when overridden). Inverse of `hive init`. The project's `.hive-state` directory on disk is not touched. Unknown name → exit 64 unless `--if-exists` makes it an exit-0 no-op. | `Hive::Commands::Forget` | [[commands/forget]] |
| `hive prune [--dry-run] [--json]` | Drop every registry entry whose `path` is no longer a directory on disk, whose stored `real_path` no longer matches the current target, OR whose row shape is invalid (hand-edit accident). `--dry-run` returns the would-be-removed list without writing. | `Hive::Commands::Prune` | [[commands/prune]] |
| `hive version` / `hive --version` | Print `Hive::VERSION` and exit 0. Used by e2e environment snapshots and binary smoke tests. | `Hive::CLI#version` | — |

`Hive::CLI` (`lib/hive/cli.rb`) is the Thor class. Notable mappings:

- `new_task` is mapped to the user-visible `new` (Thor reserves `new`).
- `generate_name` is mapped to the user-visible `generate-name`.
- `bench submit` is implemented as the `bench` Thor command with a subcommand switch; unknown bench subcommands exit USAGE (64).
- `run_task` is mapped to `run`.
- Stage verbs use `--from` for source-stage disambiguation because the verb already implies the target stage.
- `review --pr` is a special entry branch on the review verb. It refuses a simultaneous positional target, resolves the project from `--project NAME` or the current directory via the global registry, creates/reuses the ad-hoc review task, and then delegates to `StageAction` with the generated slug. `hive review 197` without `--pr` is still routed as target `197`.
  - **Reuse pins to the first-run head (known limitation).** When the `6-review/adhoc-review-pr-N/` task already exists, `review --pr` reuses it and runs the *next review pass on the same worktree* — it returns before any `gh pr view`/re-fetch and never re-materializes. So re-running after the PR author pushes new commits (including a force-push) re-reviews the **original** head; `worktree.yml`'s `execute_base_head` and the `hive/review/pr-N` branch stay pinned to the first run with no staleness warning. To pick up new commits, `hive drop adhoc-review-pr-N` and re-run `hive review --pr N` to recreate the worktree at the current head. The reuse path validates that the pr.md is genuinely this PR's ad-hoc review **and** that its worktree directory still exists on disk — a pruned/removed worktree fails cleanly at enqueue (pointing at `hive drop`) rather than deep in the review stage.
- `init` accepts `--force` (skip clean-tree check) and `--json` (single `hive-init.v1` success document with resolved answers and project metadata; precondition failures keep the legacy stderr + exit-code contract).
- `init` and `new` share one `--workflow` help string sourced from the built-in workflow registry, then append a static note that project-authored workflows are valid and can be created with `hive workflow new ID`. Thor captures (bakes) this string at class-load time and replays it later via `help`, so help does not dynamically enumerate active-project descriptors.
- `--json` is a `class_option` honoured by `init`, `status`, `run`, `rebase-status`, `approve`, `drop`, `findings`, `accept-finding`, `reject-finding`, the workflow verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`), `markers clear`, `metrics`, `forget`, `prune`, `workflow new`, `connect screenote`, `disconnect screenote`, `bench submit`, `digest`, `pairing`, the `daemon` subcommands (`status`, `stop`, `reload`, `install`, `enable`, `disable`, `queue`), and the `bot` lifecycle subcommands (`status`, `stop`, `reload`). Daemon JSON is published as `hive-daemon-status.v1` / `-stop.v1` / `-reload.v1` / `-install.v1` / `-enroll.v1` / `-queue.v1`; bot lifecycle JSON is published as `hive-bot-status.v1` / `-stop.v1` / `-reload.v1`; pairing JSON is published as `hive-pairing-list.v1` and `hive-pairing-approve.v1`. `hive babysit` is bare-text in v1. Each command with full envelope support emits a typed JSON document on success and a structured error envelope on failure. Workflow verbs emit a single `hive-stage-action` envelope (inner Approve and Run are passed `quiet: true` to avoid double-emission). `init` emits `hive-init.v1` on success; `drop` emits `hive-drop.v2` (v1 remains loadable by explicit schema version for pinned consumers); `rebase-status` emits a sibling read-only `hive-rebase-status` envelope — not validated against `hive-run.v1`; Screenote connect/disconnect emit unversioned success documents and keep failures on stderr + exit code; `workflow new`, `bench submit`, and `digest` emit unversioned success documents, and `workflow new` also emits unversioned JSON errors for its typed usage/config/git failures.
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` (including forms with command options before the help flag, such as `hive approve --from 2-brainstorm --help`) into `help <cmd>` before Thor dispatch, so the convention agents try first works without leaking command-local args into Thor's `help` command.
- `bin/hive` handles top-level `--version` / `-v` before Thor dispatch so wrappers can smoke-test the binary without parsing help output.
- `bin/hive` normalizes leading Thor-style JSON boolean forms such as `--json=true status` or `--no-json status` to command-local options and rejects unsupported `--json=<value>` assignments before Thor can leave the value behind as a positional. For `hive new`, that rejection and the command-local help rewrite stop once `PROJECT` has been found; the remaining argv is task text and is protected with a `--` sentinel before Thor dispatch.

## Exit-code contract (`Hive::ExitCodes`)

| Code | Constant | Meaning | Raised by |
|------|----------|---------|-----------|
| 0 | `SUCCESS` | command completed | — |
| 1 | `GENERIC` | unclassified `Hive::Error` | base `Hive::Error` |
| 2 | `ALREADY_INITIALIZED` | idempotent reject of `hive init` on existing project | `Hive::AlreadyInitialized` |
| 3 | `TASK_IN_ERROR` | a stage agent recorded `:error` (runner itself succeeded) | `Hive::TaskInErrorState` |
| 4 | `WRONG_STAGE` | `hive run` invoked on an inert stage (e.g. `1-inbox`) | `Hive::WrongStage` |
| 64 | `USAGE` | EX_USAGE — bad slug, malformed task path | `Hive::InvalidTaskPath` |
| 70 | `SOFTWARE` | EX_SOFTWARE — git, worktree, agent, or stage-runner failure | `GitError`, `WorktreeError`, `AgentError`, `StageError` |
| 75 | `TEMPFAIL` | EX_TEMPFAIL — retryable lock contention | `Hive::ConcurrentRunError` |
| 78 | `CONFIG` | EX_CONFIG — bad project / global config | `Hive::ConfigError` |

Codes are stable; bumping a code requires updating `test/unit/exit_codes_test.rb`. See [CONTRIBUTING.md](../CONTRIBUTING.md) "CLI contract for agent callers".

## Authentication / preconditions

The CLI itself has no auth. Preconditions checked at runtime by individual stage runners:

- Per-spawn `AgentProfile#check_version!` + `preflight!` (Claude: parses `claude --version` against `Hive::MIN_CLAUDE_VERSION = "2.1.118"`; Codex/Pi: profile-specific). Raises `AgentError` on mismatch. Default profile is `:claude`; `Stages::Base.spawn_agent(profile:)` selects an alternate via `Hive::AgentProfiles.lookup(...)`.
- `Hive::Gh.ensure_authenticated!` (called from both `Stages::OpenPr` and `Stages::Finalize`) runs `gh auth status` and exits 1 with stderr if unauthenticated. `Stages::OpenPr` invokes `Hive::Gh.push_branch!` before spawning the open-pr agent; `Stages::Finalize` invokes `Hive::Gh.push_branch` (non-`!`) so a persistent push failure surfaces as `ERROR reason=unpushed_commits` instead of an uncaught exit. The daemon-only merged-finalize-error archive path uses `Hive::Gh.pr_state` to re-confirm `MERGED` before accepting an internal archive recovery flag.
- `hive review --pr` also requires `gh` auth because it calls `gh pr view <n> --json number,url,baseRefName,headRefOid,isCrossRepository,state` before creating the task. It does not infer the project from the PR URL; the current directory or `--project NAME` must resolve to a registered project whose `.hive-state` directory exists, otherwise the command fails with a `hive init` hint.
- `Init#validate_git_repo!` rejects non-git dirs and rejects targets that are themselves worktrees (must run on the main checkout).
- `Init#validate_clean_tree!` aborts on dirty working tree unless `--force`.

## Error conventions

`Hive::Error` is the root exception. Subclasses define stage-shaped failure modes; each overrides `exit_code` so `bin/hive`'s rescue path produces the contract code automatically.

| Class | Raised by |
|-------|-----------|
| `Hive::InvalidTaskPath` | `Task#initialize` for paths not matching the regex |
| `Hive::ConcurrentRunError` | `Lock.acquire_task_lock` when another live PID owns `.lock` |
| `Hive::GitError` | `GitOps#run_git!` on non-zero git exit |
| `Hive::WorktreeError` | `Worktree#create!`/`remove!` and pointer validation |
| `Hive::AgentError` | `Agent.check_version!` |
| `Hive::ConfigError` | `Config.load`/`registered_projects` on shape mismatch |
| `Hive::StageError` | `Commands::Run#pick_runner` for unknown stage names |
| `Hive::TaskInErrorState` | `Commands::Run#report` when the stage marker is `:error` |
| `Hive::WrongStage` | `Stages::Inbox#run!` (running an agent on an inert stage) |
| `Hive::AlreadyInitialized` | `Commands::Init#call` when `hive/state` branch already exists |

A few stage runners still call `warn`/`exit N` directly for non-bug user errors that don't yet have a typed class — most notably `Init#validate_git_repo!` / `validate_clean_tree!` (exit 1), `Execute#run!` for `plan.md missing` (exit 1), and the `OpenPr` / `Finalize` network/auth abort paths. Migrating these to typed exceptions is tracked as Phase 2 follow-up work.

**Error envelopes.** Every full-envelope `--json` command (`status`, `run`, `approve`, `findings`, `accept-finding`, `reject-finding`, `markers clear`, `metrics rollback-rate`, `forget`, `prune`, and the workflow verbs `brainstorm` / `plan` / `develop` / `open-pr` / `review` / `artifacts` / `finalize` / `archive`) emits a `Hive::Schemas::ErrorEnvelope` document on stdout when an error is raised. Detect failure by `payload.ok == false`. The envelope carries `schema`, `schema_version`, `ok=false`, `error_class`, `error_kind` (a closed enum per command — see `Hive::Schemas::RunErrorKind` / `StatusErrorKind` / etc.), `exit_code` (matches the raised `Hive::Error`'s `exit_code` per `Hive::ExitCodes`), and `message`. Per-error structured extras (`candidates` for `AmbiguousSlug`, `id` for `UnknownFinding`, `path` for `DestinationCollision`, `stage` for `FinalStageReached`) appear automatically. The wrapper also emits command-shaped JSON for the pre-dispatch missing-argument cases named in `JSON_USAGE_ERROR_CONTRACTS`, so agent callers do not lose the schema contract just because Thor rejects argv before a handler is instantiated. `hive daemon queue --json` uses its own `hive-daemon-queue.v1` `ErrorPayload` arm for queue-command failures (`unknown_action`, `missing_request_id`, `internal`) so queue inspectors still receive one schema-specific document. `hive run --json` additionally preserves the existing dual-signal contract on `:error` / `:review_error` markers — the SuccessPayload is emitted to stdout BEFORE the `TaskInErrorState` raise, so the rescue's ErrorPayload is suppressed (one document, exit 3). `hive bench submit --json` is success-only today, so a raised `BenchSubmit::UsageError` still renders as `hive: ...` on stderr with exit 64. Errors that fire before the wrapper can load Hive or inspect argv (gem-load failures, shebang errors) cannot emit JSON — those remain stderr-text + exit-code only.

## Backlinks

- [[architecture]]
- [[modules/gh]] · [[modules/digest]]
- [[commands/init]] · [[commands/new]] · [[commands/workflow]] · [[commands/run]] · [[commands/rebase-status]] · [[commands/status]] · [[commands/daemon]] · [[commands/approve]] · [[commands/drop]] · [[commands/findings]] · [[commands/stage_action]] · [[commands/babysit]] · [[commands/bot]] · [[commands/pairing]] · [[commands/screenote]] · [[commands/bench-submit]] · [[commands/digest]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/review]] · [[stages/artifacts]] · [[stages/finalize]] · [[stages/done]]
