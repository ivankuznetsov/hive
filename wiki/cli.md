---
title: CLI Surface
type: api
source: bin/hive, bin/hv, lib/hive/cli.rb
created: 2026-04-25
updated: 2026-07-29
tags: [cli, api, skills, agents, operational, provisioning]
---

**TLDR**: Hive exposes a Thor CLI through `hive`, plus the `hv` collision
fallback. Human status defaults to a concise operational view; agents use
`hive status --operational --json`, bounded `hive watch --json-lines`, and
fresh tokenized `hive act` recommendations. `hive status --json` remains the
complete compatibility graph and `--full` retains the detailed human table.
`hive doctor` is read-only skill diagnosis, while `hive setup` and
`hive setup-agents` share consent-safe Hive operating-skill provisioning.

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
task text as options. The allow-list is `--workflow`/`--depends-on`/`--base` (whose value
is the next token, but only when that token exists and is not option-like — a
trailing or value-less `--workflow`/`--depends-on`/`--base` stays literal text rather than
swallowing PROJECT), their `--workflow=VALUE`/`--depends-on=VALUE`/`--base=VALUE` `name=`-prefix
forms, and JSON booleans lifted only in their exact accepted forms (`--json`,
`--json=true`, `--no-json`, etc.). Non-allow-listed tokens such
as `--help`, unsupported-looking `--json=...` assignments after `PROJECT`,
unrecognized `--foo`, and quoted strings containing `--workflow` remain task
text. When the wrapper itself catches a usage error, JSON-vs-prose mode is
decided from the last recognized JSON boolean flag in argv, so a trailing false
form such as `--no-json` or `--json=false` overrides an earlier `--json`.
Before any wrapper rewrite or Thor dispatch, every `ARGV` entry must be valid
UTF-8 regardless of the process locale. Invalid-byte arguments raise through
the same usage-error path as malformed wrapper options, so JSON callers still
receive the command-specific error envelope instead of a Ruby/Thor backtrace.

When a JSON request fails in Thor before the command object runs, `bin/hive`
uses `JSON_USAGE_ERROR_CONTRACTS` to keep the error shaped like the requested
surface. Missing-target, missing-project, missing-service, or extra-argument
usage errors for `setup`, `connect`, `disconnect`, `run`, `rebase-status`,
workflow verbs, `approve`, `drop`, `findings`, `accept-finding`,
`reject-finding`, `markers`, and `patrol` emit command-specific JSON on stdout
before the human `hive:` stderr line. Schemas registered in
`Hive::Schemas::SCHEMA_VERSIONS` use `Hive::Schemas::ErrorEnvelope` and include
`schema_version`; the older `hive-rebase-status` inspector keeps its unversioned
sibling shape, setup uses the versioned `hive-setup.v1` contract, and Screenote
`connect`/`disconnect` keep their schema-less `ok:false`,
`service:"screenote"` failure document. Workflow verbs include the `verb` extra
(`pr` maps to `open-pr`), finding toggles include `operation`, and patrol's
pre-dispatch usage failure uses the `hive-patrol` schema with
`error_kind: "error"`.

Partial `hive act ... --json` invocations use the `hive-act` usage envelope and
preserve whichever required positionals were available as `action_id` and
`target`; a missing positional is represented by an empty string. This lets an
agent correlate a rejected action without parsing Thor's prose.

The pre-dispatch resolver is command/subcommand-aware for JSON surfaces whose
schema varies by argv. It distinguishes status diagnostics, web install/status,
pairing list/approve, and shipped/merged-PR digest errors; it also covers Thor
arity failures for status, prune, forget, metrics, bot, and the documented web
commands. Option values cannot impersonate subcommands, and flags after the
`--` terminator remain positional data rather than switching the status or
digest schema. Existing setup, Screenote connect/disconnect, and other static
contracts retain their established unversioned or schema-less shapes.

`bin/hv` is a bash fallback launcher for Apache Hive name collisions. It deliberately avoids `command -v hive`; instead it probes only `HIVE_BIN_OVERRIDE`, `${XDG_BIN_HOME:-$HOME/.local/bin}/hive`, `${HOMEBREW_PREFIX:-/opt/homebrew}/bin/hive`, and `/usr/local/bin/hive`, skipping a target that resolves back to itself. Each `--version` probe runs in its own process group with temp-file stdout capture and a watchdog/KILL sweep, so a bad candidate cannot keep `hv` blocked by forking a stdout-inheriting child. When the watchdog's timeout elapses it records a sentinel, and `probe_version` forces a non-zero (124, mirroring GNU `timeout`) status regardless of the probe's own exit code — so a candidate that prints a bare semver and then hangs (trapping the watchdog's TERM to exit 0) is rejected rather than exec'd. It does not implicitly exec `/usr/bin/hive` or `/opt/hive/bin/hive`, because those paths may be Apache Hive installs. If no candidate is executable it exits `127` and tells the operator to set `HIVE_BIN_OVERRIDE` or install through the documented channels. `bin/hv` remains in the gem payload for channel installers to copy/read, but it is not listed in `spec.executables`; RubyGems would otherwise generate a Ruby binstub for this bash launcher. See [[operating]] for channel-level `hv` behavior.

## Command table

| Command | Synopsis | Routes to | Page |
|---------|----------|-----------|------|
| `hive init [PROJECT_PATH] [--json] [--refactor-patrol\|--no-refactor-patrol]` | Bootstrap `.hive-state` plus managed llm-wiki context; fresh projects enable architecture discovery by default, and the boolean flag resolves it before any state write; `--json` emits `hive-init.v2` | `Hive::Commands::Init` | [[commands/init]] |
| `hive new PROJECT TEXT... [--workflow ID] [--depends-on TASK] [--base BRANCH] [--json]` | Create a task in `1-inbox/` of a registered project, writing the request plus `meta.yml`; `--base` records the exact non-stacked origin base for managed draft-PR workflows, and stdout uses the numeric task id when allocation succeeds | `Hive::Commands::New` | [[commands/new]] |
| `hive workflow new ID [--json]` | Scaffold a blank per-project workflow descriptor plus placeholder instruction under `<hive_state_path>/workflows/` | `Hive::Commands::Workflow` | [[commands/workflow]] |
| `hive workflow commit ID` | Validate and commit a populated owner-authored workflow under the shared Hive state commit lock | `Hive::Commands::Workflow` | [[commands/workflow]] |
| `hive generate-name TARGET [--project NAME] [--stage STAGE]` | Generate and persist a short display title for a task; target resolves by path, slug, or numeric id | `Hive::Commands::GenerateName` | [[commands/generate-name]] |
| `hive status [--operational [--json] \| --full \| --diagnose SLUG ...]` | Default/`--operational` is the concise closed-state human view; `--operational --json` emits `hive-operational-status.v3`; bare `--json` emits complete `hive-status.v7`; `--full` retains the detailed table. Diagnosis keeps its existing bounded read/write surface. | `Hive::Commands::Status` | [[commands/status]] |
| `hive watch TARGET... [--project NAME] [--until settled\|completion] [--json-lines]` | Resolve at most 100 tasks once and emit only semantic initial/transition/warning/final events until a terminal condition, timeout, or event cap. Read-only; global `--json` is rejected. | `Hive::Commands::Watch` | [[commands/watch]] |
| `hive act ACTION_ID TARGET --observation TOKEN [--json]` | Re-resolve and lock one exact task, verify a fresh command-free routine action descriptor, and dispatch only the recomputed closed workflow advance. | `Hive::Commands::Act` → `Hive::OperationalAction::Executor` | [[commands/status]] |
| `hive setup [--json] [--service\|--no-service] [--no-bootstrap] [--no-init] [--yes]` | Agent-skills-first native workstation provisioning with one consent boundary, then QMD/authenticated web bundle, daemon, optional project enrollment, and the default loopback web service. JSON/non-TTY without `--yes` performs no mutation; `--no-service` opts out of web-service mutation; `--no-bootstrap` is diagnose-only. JSON is `hive-setup.v1`. | `Hive::Commands::Setup` | [[commands/setup]] |
| `hive setup-agents [--yes] [--json] [--agent NAME...] [--skill ID...]` | Preview, consent to, execute, and verify bundled Hive projections plus unresolved manifest-managed Claude/Codex/Pi capabilities. JSON mutation requires `--yes`; OpenClaw remains read-only/external. | `Hive::Commands::SetupAgents` → `Hive::AgentSkills::Provisioner` | [[commands/setup-agents]] |
| `hive tui` | Live, keystroke-driven Charm bubbletea + lipgloss dashboard over `hive status` (human-only; rejects `--json`) | `Hive::Tui` | [[commands/tui]] |
| `hive daemon SUBCOMMAND` | Auto-advance pipeline dispatcher. Subcommands: `start` / `stop` / `status` / `reload` / `tail` for the daemon process; `install [--force]` to (re)write the platform-native unit file (preserves operator hand-edits without `--force`; rotates the prior file to `<path>.bak-<ts>` and restarts the daemon with `--force`); `enable PROJECT \| --all` and `disable` for per-project enrollment (atomic write to `<project>/.hive-state/config.yml`); `queue [list \| show <id> \| prune]` for read-only inspection of the adapter request queue the daemon consumes (runs in the CLI process, no daemon contact; `--json` emits `hive-daemon-queue.v1`). Polls `hive status --json` and fires workflow verbs on tasks ready to advance; auto-archives 8-finalize after PR merge. `Hive::Daemon::StaleAgentHealer` rewrites stale in-flight ownership to durable errors and is the sole automatic scheduler for cooled `ERROR` / `REVIEW_ERROR` observations. `RecoveryCoordinator` then owns exact marker identity, task-lock safety, the v4 retry request, guarded clear, and restart replay for every stage without an exhaustion cap or stage-specific mechanism. Daemon autostart is installed globally via `hive daemon install`; new projects opt in to dispatch at `hive init` (default Y), and existing ones via `hive daemon enable`. See [[operating]] for the install + systemd/launchd setup guide. | `Hive::Commands::Daemon` | [[commands/daemon]] |
| `hive babysit SUBCOMMAND [PROJECT]` | Experimental PR babysitter. Subcommands: `start` / `stop` / `restart` / `status` / `reload` / `tail`, plus `--once PROJECT` or `--once --all` for one-shot passes. Separate from `hive daemon`; polls open GitHub PRs for projects with `babysitter.enabled: true`, skips ignored labels, spawns the configured development agent in `.hive-state/babysitter/worktrees/<pr>/`, and labels/comments only on give-up. `reload` refreshes config/log settings but not Ruby code; `status` recommends `hive babysit restart --detach` when the running PID predates the current source checkout. | `Hive::Commands::Babysit` | [[commands/babysit]] |
| `hive bot SUBCOMMAND` | Telegram bot lifecycle. Subcommands: `start` / `stop` / `status` / `reload` / `tail`. Long-polls Telegram, authenticates by `bot.chat_id_allowlist`, notifies on waiting/recovery gates, and dispatches existing `hive` commands from inline buttons. | `Hive::Commands::Bot` | [[commands/bot]] |
| `hive pairing SUBCOMMAND` | Telegram pairing approval. `list` shows pending first-contact `/start` codes; `approve telegram <CODE>` appends the chat id to `bot.chat_id_allowlist`, reloads the bot when running, and queues the approved DM. | `Hive::Commands::Pairing` | [[commands/pairing]] |
| `hive brainstorm TARGET [--from STAGE]` | Start or re-run brainstorm by slug/path | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive plan TARGET [--from STAGE]` | Promote completed brainstorm to plan, or re-run plan | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive develop TARGET [--from STAGE]` | Promote completed plan to execute, or re-run execute | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive open-pr TARGET [--from STAGE]` | Promote completed execute to draft PR creation, or re-run open-pr | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive review TARGET [--from STAGE]` | Promote opened draft PR to review, or re-run review. Bare numeric targets remain task ids. | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive review --pr PR [--project NAME] [--json]` | Create or reuse a synthetic ad-hoc `6-review/adhoc-review-pr-N/` task for an existing GitHub PR (`N`, `#N`, or a `/pull/N` URL), materialize the PR head into the normal worktree root, then run review through the same StageAction path. | `Hive::Commands::AdhocReview` → `Hive::Commands::StageAction` | [[commands/stage_action]], [[stages/review]] |
| `hive artifacts TARGET [--from STAGE]` | Promote completed review to artifact collection, or re-run artifacts | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive finalize TARGET [--from STAGE]` | Promote completed artifacts to PR finalization, or re-run finalize | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive archive [TARGET] [--from STAGE]` | With no target, list every `9-done` task across registered projects through Status archive mode (`--json` returns a `hive-status` payload filtered to done rows). With a target, promote a completed finalized PR to done, re-run done, or use the explicit evidence-bound `--reason already_delivered|superseded` operator flow. Automatic task-bound merge closure uses an internal receipt API, not a CLI bypass flag. | no target: `Hive::Commands::Status`; target: `Hive::Commands::StageAction` / `Hive::TaskClosure` | [[commands/status]], [[commands/stage_action]] |
| `hive connect screenote [--base-url URL] [--json]` | Run Screenote OAuth 2.1 auth-code + PKCE setup, pick a default Screenote project via MCP `list_projects`, and persist `screenote.json` for artifacts-stage MCP injection. | `Hive::Commands::Connect` | [[commands/screenote]] |
| `hive disconnect screenote [--json]` | Revoke the stored Screenote token when possible and clear `screenote.json`; no-op when already disconnected. | `Hive::Commands::Disconnect` | [[commands/screenote]] |
| `hive bench submit SLUG [--project NAME] [--json]` | Extract a completed `9-done` task into a hive-bench corpus entry and open a submission PR from the hive-bench checkout. Requires `HIVE_BENCH_PATH` or `~/Dev/hive-bench`, a GitHub `origin` remote for the source project, `worktree.yml`, `pr.md`, and a clean local secret-token preflight. | `Hive::Commands::BenchSubmit` | [[commands/bench-submit]] |
| `hive refactor-patrol PROJECT [--list \| --show JOB_ID] [--limit N] [--cursor CURSOR] [--full] [--json]` | Run architecture-patrol modes, or inspect the authoritative durable job ledger without mutation. List pages and show histories default to 100 records; list cursors freeze an immutable intake-sequence high-water and show requires explicit `--full` for unbounded histories. JSON uses `hive-refactor-patrol-jobs.v1`. | `Hive::Commands::RefactorPatrol` → `Hive::RefactorPatrol::JobQuery` | [[commands/refactor-patrol]] |
| `hive run TARGET [--no-rebase]` | Lower-level dispatcher for a slug or task folder. `--no-rebase` skips the auto-rebase pre-step for one invocation (one-off override of `cfg.rebase.enabled`). | `Hive::Commands::Run` → stage runner | [[commands/run]] |
| `hive rebase-status TARGET` | Read-only inspector: reports whether the next `hive run` would attempt an auto-rebase, how many commits behind `origin/<default>` the worktree is, and which guard (if any) would short-circuit. Never mutates; never calls `git fetch`. | `Hive::Commands::RebaseStatus` | [[commands/rebase-status]] |
| `hive approve TARGET [--to STAGE] [--from STAGE]` | Move a task between stages + record a hive/state commit (agent-callable equivalent of shell `mv`; `--from` asserts current stage for retry idempotency) | `Hive::Commands::Approve` | [[commands/approve]] |
| `hive decide TARGET OUTCOME --from STAGE --decision-id ID [--note TEXT] [--json]` | Apply one descriptor-declared human outcome to the observed stage visit; completing outcomes atomically verify a non-marker artifact. | `Hive::Commands::Decide` | [[commands/workflow]] |
| `hive drop TARGET [--project NAME] [--from STAGE]` | Hard-delete an active task: kill its recorded agent, close draft PR best-effort, remove task folder(s), logs, worktree, branch, and locks, then commit an audit record. Refuses `9-done`. | `Hive::Commands::Drop` | [[commands/drop]] |
| `hive findings TARGET [--pass N] [--stage STAGE]` | List GFM-checkbox findings in `reviews/ce-review-NN.md` (latest by default) | `Hive::Commands::Findings` | [[commands/findings]] |
| `hive accept-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Tick `[x]` on review findings; selectors are unioned | `Hive::Commands::FindingToggle` (accept) | [[commands/findings]] |
| `hive reject-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Untick `[x]` on review findings | `Hive::Commands::FindingToggle` (reject) | [[commands/findings]] |
| `hive markers clear FOLDER --name <NAME> [--match-attr KEY=VALUE] [--project NAME] [--json]` | Low-level explicit operator repair: remove a recovery marker (`REVIEW_STALE`, `REVIEW_CI_STALE`, `REVIEW_ERROR`, `EXECUTE_STALE`, `ERROR`) from a task's state file (atomic write + hive_commit). Normal user-facing and automatic recovery submit through `Hive::Recovery::API`, where `RecoveryCoordinator` owns the guarded clear and retry. Terminal-success markers (`REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE`) are deliberately rejected — use `hive approve` instead. `--match-attr KEY=VALUE` refuses the clear unless the current marker carries the named attribute (exit 4 on mismatch), preventing an operator from erasing a replacement occurrence. | `Hive::Commands::Markers` | [[commands/markers]] |
| `hive metrics SUBCOMMAND [--days N] [--project NAME] [--json]` | Compute project-wide metrics. Currently one subcommand: `rollback-rate` walks `git log --all` and reports the fraction of fix-commits (those carrying `Hive-Fix-Pass` trailer) that were later reverted, broken down by `Hive-Triage-Bias` and `Hive-Fix-Phase`. | `Hive::Commands::Metrics` → `Hive::Metrics` | — |
| `hive update` | Re-run the install channel that originally placed the binary (xdg/homebrew/aur). Reads channel from `~/.local/state/hive/install-channel` (or `Hive::InstallChannel.detect`) and re-invokes the matching installer; refuses to act when the channel is unknown. See `lib/hive/commands/update.rb`. | `Hive::Commands::Update` | — |
| `hive uninstall [--purge]` | Remove user-scoped hive runtime: stop daemon/bot, remove launchd/systemd units, drop xdg-installed binary, prune `~/.local/state/hive`. `--purge` also removes the global registry at `~/.config/hive/config.yml` (or `HIVE_HOME/config.yml` when overridden). Never touches per-project `.hive-state/` working trees. See `lib/hive/commands/uninstall.rb`. | `Hive::Commands::Uninstall` | — |
| `hive migrate [PROJECT_PATH]` | Migrate legacy project config, rename older in-flight task folders, backfill task metadata, and assign identities to pre-v2 recoverable markers. | `Hive::CLI#migrate` | [[commands/migrate]] |
| `hive refactor-patrol-migrate-installed [--all-users]` | Candidate-only JobStore sweep. The default owns one exact user profile; root-only `--all-users` discovers fixed NSS-user registries plus root-inventoried custom roots, drops identity per profile, and emits coverage-aware aggregate evidence. First use is fallback only. | `Hive::Commands::RefactorPatrolCandidateMigration` | [[commands/migrate]] |
| `hive doctor [--json]` | Read-only inspection of always-required Hive operating skills, configured managed capabilities, native resolution/provenance, and OpenClaw/ClawHub inventory. Emits `hive-doctor.v2`; legacy checks remain separate. | `Hive::Commands::Doctor` | [[commands/doctor]] |
| `hive forget NAME [--if-exists] [--json]` | Drop one named entry from the global registry (`~/.config/hive/config.yml`, or `HIVE_HOME/config.yml` when overridden). Inverse of `hive init`. The project's `.hive-state` directory on disk is not touched. Unknown name → exit 64 unless `--if-exists` makes it an exit-0 no-op. | `Hive::Commands::Forget` | [[commands/forget]] |
| `hive prune [--dry-run] [--json]` | Drop every registry entry whose `path` is no longer a directory on disk, whose stored `real_path` no longer matches the current target, OR whose row shape is invalid (hand-edit accident). `--dry-run` returns the would-be-removed list without writing. | `Hive::Commands::Prune` | [[commands/prune]] |
| `hive version` / `hive --version` | Print `Hive::VERSION` and exit 0. Used by e2e environment snapshots and binary smoke tests. | `Hive::CLI#version` | — |

`Hive::CLI` (`lib/hive/cli.rb`) is the Thor class. Notable mappings:

- `new_task` is mapped to the user-visible `new` (Thor reserves `new`).
- `generate_name` is mapped to the user-visible `generate-name`.
- `bench submit` is implemented as the `bench` Thor command with a subcommand switch; unknown bench subcommands exit USAGE (64).
- `run_task` is mapped to `run`.
- Stage verbs use `--from` for source-stage disambiguation because the verb already implies the target stage.
- `init` accepts `--force`, `--json`, and the pre-write `--refactor-patrol` / `--no-refactor-patrol` discovery choice. Omitting the boolean keeps fresh discovery enabled. The same fresh-init choice enables or disables deduplicated GitHub issue output; auto-fixing remains disabled.
- `init` and `new` share one `--workflow` help string sourced from the built-in workflow registry, then append a static note that project-authored workflows are valid and can be created with `hive workflow new ID`. Thor captures (bakes) this string at class-load time and replays it later via `help`, so help does not dynamically enumerate active-project descriptors.
- `--json` is a `class_option` honoured by `init`, `status`, `act`, `doctor`, `setup-agents`, `run`, `rebase-status`, `approve`, `drop`, `findings`, `accept-finding`, `reject-finding`, the workflow verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`), `markers clear`, `metrics`, `forget`, `prune`, `workflow new`, `connect screenote`, `disconnect screenote`, `bench submit`, `pairing`, the `daemon` subcommands (`status`, `stop`, `reload`, `install`, `enable`, `disable`, `queue`), and the `bot` lifecycle subcommands (`status`, `stop`, `reload`). `watch` rejects that single-document mode and uses `--json-lines`. Doctor emits `hive-doctor.v2`; setup emits `hive-setup.v1`; setup-agents emits `hive-setup-agents.v1`, never prompts in JSON mode, and requires `--yes` for mutation. Status selects `hive-status.v7` unless `--operational` selects the recovery-aware `hive-operational-status.v3`; the closure/recovery migration removed superseded operational-status v1/v2 and act v1 contracts. Daemon JSON is published as `hive-daemon-status.v1` / `-stop.v1` / `-reload.v1` / `-install.v1` / `-enroll.v1` / `-queue.v1`; bot lifecycle JSON is published as `hive-bot-status.v1` / `-stop.v1` / `-reload.v1`; pairing JSON is published as `hive-pairing-list.v1` and `hive-pairing-approve.v1`. `hive babysit` is bare-text in v1. Each command with full envelope support emits a typed JSON document on success and a structured error envelope on failure. Workflow verbs emit a single `hive-stage-action` envelope. `init` emits `hive-init.v2` on success (v1 remains loadable for pinned consumers); `drop` emits `hive-drop.v2`; `rebase-status` emits `hive-rebase-status`; and Screenote/workflow/bench keep their existing contracts.
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` (including forms with command options before the help flag, such as `hive approve --from 2-brainstorm --help`) into `help <cmd>` before Thor dispatch, so the convention agents try first works without leaking command-local args into Thor's `help` command.
- `bin/hive` handles top-level `--version` / `-v` before Thor dispatch so wrappers can smoke-test the binary without parsing help output.
- `bin/hive` normalizes leading Thor-style JSON boolean forms such as `--json=true status` or `--no-json status` to command-local options and rejects unsupported `--json=<value>` assignments before Thor can leave the value behind as a positional. For `hive new`, that rejection and the command-local help rewrite stop once `PROJECT` has been found; the remaining argv is task text and is protected with a `--` sentinel before Thor dispatch.

## Exit-code contract (`Hive::ExitCodes`)

| Code | Constant | Meaning | Raised by |
|------|----------|---------|-----------|
| 0 | `SUCCESS` | command completed | — |
| 1 | `GENERIC` | unclassified failure; setup-agents attempted/residual failure | base `Hive::Error`, `SetupAgents` result |
| 2 | `ALREADY_INITIALIZED` | idempotent reject of `hive init` on existing project | `Hive::AlreadyInitialized` |
| 3 | `TASK_IN_ERROR` | a stage agent recorded `:error` (runner itself succeeded) | `Hive::TaskInErrorState` |
| 4 | `WRONG_STAGE` | `hive run` invoked on an inert stage (e.g. `1-inbox`) | `Hive::WrongStage` |
| 64 | `USAGE` | EX_USAGE — bad arguments, or setup-agents consent declined/missing without TTY/`--yes` | `Hive::UsageError`; `Hive::InvalidTaskPath` for task/path failures and preserved `invalid_task_path` contracts; `SetupAgents` |
| 70 | `SOFTWARE` | EX_SOFTWARE — git, worktree, agent, or stage-runner failure | `GitError`, `WorktreeError`, `AgentError`, `StageError` |
| 75 | `TEMPFAIL` | EX_TEMPFAIL — retryable lock contention | `Hive::ConcurrentRunError` |
| 78 | `CONFIG` | EX_CONFIG — bad project/global config or invalid agent-skills manifest/filter | `Hive::ConfigError`, `SetupAgents` |

Codes are stable; bumping a code requires updating `test/unit/exit_codes_test.rb`. See [CONTRIBUTING.md](../CONTRIBUTING.md) "CLI contract for agent callers".

## Authentication / preconditions

The CLI itself has no auth. Preconditions checked at runtime by individual stage runners:

- Per-spawn `AgentProfile#check_version!` + `preflight!` (Claude: parses `claude --version` against `Hive::MIN_CLAUDE_VERSION = "2.1.118"`; Codex/Pi/Grok: profile-specific). Grok accepts API keys, device-login credentials, `GROK_AUTH_PATH`, and `GROK_HOME`, with the direct auth path taking precedence. Raises `AgentError` on mismatch. Default profile is `:claude`; `Stages::Base.spawn_agent(profile:)` selects an alternate via `Hive::AgentProfiles.lookup(...)`.
- `Hive::Gh.ensure_authenticated!` (called from both `Stages::OpenPr` and `Stages::Finalize`) runs `gh auth status` and exits 1 with stderr if unauthenticated. `Stages::OpenPr` invokes `Hive::Gh.push_branch!` before spawning the open-pr agent; `Stages::Finalize` invokes `Hive::Gh.push_branch` (non-`!`) so a persistent push failure surfaces as `ERROR reason=unpushed_commits` instead of an uncaught exit. The daemon-only merged-finalize-error archive path uses `Hive::Gh.pr_state` to re-confirm `MERGED` before accepting an internal archive recovery flag.
- `Init#validate_git_repo!` rejects non-git dirs and rejects targets that are themselves worktrees (must run on the main checkout).
- `Init#validate_clean_tree!` aborts on dirty working tree unless `--force`.

## Error conventions

`Hive::Error` is the root exception. Subclasses define stage-shaped failure modes; each overrides `exit_code` so `bin/hive`'s rescue path produces the contract code automatically.

| Class | Raised by |
|-------|-----------|
| `Hive::UsageError` | Generic command-line argument/usage failures that do not imply an invalid task path |
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

`Hive::UsageError` is the canonical generic usage exception. `Hive::InvalidTaskPath`
remains for actual task/path resolution failures and for established structured
surfaces whose public `error_kind` is `invalid_task_path`; callers must not infer
that every exit `64` denotes an invalid task path.

A few stage runners still call `warn`/`exit N` directly for non-bug user errors that don't yet have a typed class — most notably `Init#validate_git_repo!` / `validate_clean_tree!` (exit 1), `Execute#run!` for `plan.md missing` (exit 1), and the `OpenPr` / `Finalize` network/auth abort paths. Migrating these to typed exceptions is tracked as Phase 2 follow-up work.

**Error envelopes.** Every full-envelope `--json` command (`status`, `run`, `approve`, `findings`, `accept-finding`, `reject-finding`, `markers clear`, `metrics rollback-rate`, `forget`, `prune`, and the workflow verbs `brainstorm` / `plan` / `develop` / `open-pr` / `review` / `artifacts` / `finalize` / `archive`) emits a `Hive::Schemas::ErrorEnvelope` document on stdout when an error is raised. Detect failure by `payload.ok == false`. The envelope carries `schema`, `schema_version`, `ok=false`, `error_class`, `error_kind` (a closed enum per command — see `Hive::Schemas::RunErrorKind` / `StatusErrorKind` / etc.), `exit_code` (matches the raised `Hive::Error`'s `exit_code` per `Hive::ExitCodes`), and `message`. Per-error structured extras (`candidates` for `AmbiguousSlug`, `id` for `UnknownFinding`, `path` for `DestinationCollision`, `stage` for `FinalStageReached`) appear automatically when the command's closed schema permits them; `hive-markers-clear.v1` intentionally retains its narrower key set and does not expose commit-lock holder/path metadata. If encoding the error payload itself raises `JSON::GeneratorError`, `run` and `status` preserve their original silent fallback to the typed exit code; `approve`, findings/toggles, markers, and workflow stage actions preserve their original raised generator error; and the emitter's earlier consumers (`daemon`, `adhoc-review`, `drop`, `forget`, and `prune`) preserve the shared default that warns and then re-raises the original typed failure. The wrapper also emits command-shaped JSON for the pre-dispatch missing-argument cases named in `JSON_USAGE_ERROR_CONTRACTS`, so agent callers do not lose the JSON contract just because Thor rejects argv before a handler is instantiated; that includes the unversioned `hive-setup` usage payload and Screenote's schema-less `ok:false`, `service:"screenote"` usage payloads. `hive daemon queue --json` uses its own `hive-daemon-queue.v1` `ErrorPayload` arm for queue-command failures (`unknown_action`, `missing_request_id`, `internal`) so queue inspectors still receive one schema-specific document. `hive run --json` additionally preserves the existing dual-signal contract on `:error` / `:review_error` markers — the SuccessPayload is emitted to stdout BEFORE the `TaskInErrorState` raise, so the rescue's ErrorPayload is suppressed (one document, exit 3). `hive bench submit --json` is success-only today, so a raised `BenchSubmit::UsageError` still renders as `hive: ...` on stderr with exit 64. Errors that fire before the wrapper can load Hive or inspect argv (gem-load failures, shebang errors) cannot emit JSON — those remain stderr-text + exit-code only.

## Backlinks

- [[architecture]]
- [[modules/gh]]
- [[commands/init]] · [[commands/new]] · [[commands/workflow]] · [[commands/run]] · [[commands/rebase-status]] · [[commands/status]] · [[commands/watch]] · [[commands/daemon]] · [[commands/refactor-patrol]] · [[commands/approve]] · [[commands/drop]] · [[commands/findings]] · [[commands/stage_action]] · [[commands/babysit]] · [[commands/bot]] · [[commands/pairing]] · [[commands/screenote]] · [[commands/bench-submit]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/review]] · [[stages/artifacts]] · [[stages/finalize]] · [[stages/done]]
