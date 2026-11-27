# Hive CLI Reference

`docs/cli.md` is the canonical public CLI reference for the command surface exposed by `bin/hive` (`hive` / `hv`) for external users, contributors, and automation or coding agents. Machine-validation JSON schemas live under [schemas/](../schemas/); internal controller, storage, and subsystem architecture live under [wiki/cli.md](../wiki/cli.md) and linked Wiki pages.

## Authority, Wrapper, And Vocabularies

### Wrapper And Argument Grammar

- **Executable and alias:** `bin/hive` (also invoked as `hv` when linked) runs context preflight, help rewriting, and boolean JSON normalization before invoking Thor (`Hive::CLI.start`).
- **Context preflight (`--context NAME`):** `--context NAME` (or `--context=NAME`) overrides the saved client context for one invocation before local runtime activation or project discovery. `context_management` commands (`context`, `help`, `tree`, `version`) always run client-side. `supported_remote` commands (`status`, `task`, `new`, `act`, `answer`, `approve`, `operation`) call HTTPS when a remote context is active. All other visible commands are `local_only` and fail closed under a remote context with `<command> requires a local context; specify --context local` and exit `64`.
- **Boolean `--json` grammar:** `--json` is inherited by every command. Wrapper and remote preflight accept `--json`, `--no-json`, `--skip-json`, and explicit boolean assignments (`--json=true|false|TRUE|FALSE|t|f|T|F`), rejecting non-boolean `--json=VALUE` assignments before dispatch with exit `64`. Each leaf below states whether `--json` produces a single JSON document, JSON Lines, a success-only JSON document, is rejected (exit `64`), or is ignored (text-only).
- **Help and version rewriting:** `hive COMMAND --help` (or `-h`, `-?`, `-D`) is rewritten to `hive help COMMAND` before dispatch without running `COMMAND`, except past `--` or inside `hive new PROJECT TEXT` task prose. `hive --version` and `hive -v` route to `hive version`. `hive pr` aliases `hive open-pr`. `hive --tree` and `hive -t` route to `hive tree`.
- **Option lifting on `hive new`:** Wrapper normalization lifts known `new` flags (`--base`, `--depends-on`, `--workflow`, `--idempotency-key`, `--json`, `--context`) placed between `PROJECT` and `TEXT` while leaving everything after `--` or inside task prose literal.
- **Literal `--` boundary:** Arguments after `--` are passed literally without flag interpretation.
- **Mutation context banner:** When a local mutating invocation runs, preflight prints `hive: context=local installation=local authority=unrestricted-local-operator target=<target>` to stderr (never stdout).

### Closed Vocabularies

- **Support classes:** `stable` (supported public contract), `experimental` (opt-in or evolving public surface), `maintenance` (operator recovery, database, receipt, queue, or installation maintenance), `deprecated` (retained for compatibility only), `visible_internal` (visible in `bin/hive help` but scoped to internal controllers, producers, or workers). `private` is reserved exclusively for hidden commands, hidden options, and pre-Thor routes listed under [Excluded Hidden and Private Routes](#excluded-hidden-and-private-routes).
- **Coverage states:** `full` (every required field documented from direct evidence) or `checked_exception` (documented leaf carrying an explicit `Exception` naming `field`, `evidence`, `owner`, and `follow_up` while documenting every non-excepted field).
- **Evidence states:** `top_level`, `structured_synopsis`, `registry_expanded_placeholder`, `inline_help_and_dispatcher`, and `catalog_declared_with_exception` (permitted only for `context` and `token` until Thor help or a named registry publishes their selector sets).
- **Context postures:** `context_management`, `supported_remote`, and `local_only` (matching `Hive::Remote::CommandPolicy.classify`).

## Day-To-Day Workflow

Start with `hive setup` (native loopback web at `http://127.0.0.1:4567`, daemon service, and project enrollment), create work with `hive new PROJECT TEXT`, poll active work with `hive status` / `hive status --operational`, inspect a single task with `hive task TARGET`, and advance tasks with the stage verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`) or `hive decide` for custom human stages. Stage verbs promote then run when the task sits at the previous stage, and only run when already at the target stage. See [Command Catalog](#command-catalog) for exact signatures, options, schemas, modes, and exits.

## Findings Triage

Use `hive findings TARGET` to list GFM checkbox findings from the latest review pass (`reviews/ce-review-NN.md`), `hive accept-finding TARGET [ID...]` to tick findings for the next fix pass, and `hive reject-finding TARGET [ID...]` to untick them. Selectors support explicit IDs, `--severity`, `--pass`, and `--all`.

## Patrol

Use `hive patrol PROJECT` for ordinary defect patrol (`hive-patrol.v3`, with `--list` emitting `hive-patrol-findings.v1` and `--once` emitting `hive-one-shot.v1`) and `hive refactor-patrol PROJECT` for language-neutral architecture patrol (`hive-refactor-patrol.v4`, with `--list` / `--show` emitting `hive-refactor-patrol-jobs.v2` using 100-record default pages and an immutable intake-sequence high-water cursor, and `--once` emitting `hive-one-shot.v1`).

## Daemon

The daemon is global user infrastructure (`hive daemon install`, `start`, `stop`, `status`, `quiesce`, `resume`, `reload`, `tail`, `queue`, `clear-hold`, plus `--once PROJECT`), while dispatch enrollment is per-project (`hive daemon enable` / `disable`). Every public daemon subcommand JSON contract is version 1 (`hive-daemon-status.v1`, `hive-daemon-quiesce.v1`, `hive-daemon-resume.v1`, `hive-daemon-stop.v1`, `hive-daemon-reload.v1`, `hive-daemon-install.v1`, `hive-daemon-enroll.v1`, `hive-daemon-queue.v1`), and `hive daemon --once PROJECT` emits `hive-one-shot.v1`.

## Diagnostics

Use `hive doctor` (`hive-doctor.v2`) for read-only managed skill inspection, `hive setup-agents` (`hive-setup-agents.v1`) for native skill provisioning, `hive version` (`hive-version.v1`) for version inspection, `hive forget` / `hive prune` for global registry cleanup, `hive runtime status|projects|payloads|init` for runtime database maintenance, and `hive metrics rollback-rate` for fix-agent rollback metrics.

## Lower-Level Surface

Automation, recovery, and workflow-authoring primitives include `hive run`, `hive approve`, `hive act`, `hive answer`, `hive watch`, `hive markers clear`, `hive rebase-status`, `hive publication-reconcile`, `hive review-grant`, `hive stack`, `hive worktree`, `hive evidence`, `hive plan-review`, `hive receipt`, `hive proposal`, `hive module`, `hive workflow`, `hive bot`, `hive pairing`, `hive babysit`, `hive tui`, `hive web`, `hive connect` / `disconnect`, `hive mcp`, `hive digest` / `answer-digest`, `hive bench submit`, `hive wiki compile-log`, `hive context`, `hive token`, `hive operation`, and `hive tree`.

## JSON Output

Every visible command inherits `--json`, but actual framing depends on the leaf:

- **Single-document JSON (typed envelope on success and error):** Most commands emit one JSON object to stdout conforming to their versioned schema under [schemas/](../schemas/) and document their `JSON::GeneratorError` serialization policy (`:suppress`, `:raise`, or `:warn`).
- **JSON Lines (`--json-lines` or streaming `--json`):** `hive watch` rejects `--json` (exit `64`) and streams `hive-watch-event.v1` JSON Lines via `--json-lines`. `hive connect screenote --json` streams an `authorize` JSON line followed by the final outcome line.
- **Success-only JSON:** Local `hive task --json`, `hive bench submit --json`, `hive publication-reconcile --json`, and `hive evidence recover|rework|terminal|server --json` emit JSON on success and report errors on stderr without a JSON error envelope.
- **Explicitly rejected `--json` (exit `64`):** `hive watch`, `hive tui`, `hive web` (bare, `start`, `stop`), `hive daemon clear-hold`, `hive mcp login`, and `hive workflow commit`.
- **Ignored `--json` (text-only):** `hive help`, `hive tree`, `hive generate-name`, `hive plan-review-run`, `hive update`, `hive uninstall`, `hive wiki compile-log`, `hive daemon start|tail` (warns on stderr), `hive bot start|tail`, `hive babysit` named subcommands, and `hive evidence browser`.

## Remote Context

Save a remote HTTPS installation with `hive context add NAME --url URL --token-stdin` and select it with `hive context use NAME`, or pass `--context NAME` for one invocation. Under a remote context:

- `context`, `help`, `tree`, and `version` stay on the client (`context_management`).
- `status`, `task`, `new`, `act`, `answer`, `approve`, and `operation` run over HTTPS (`supported_remote`). Successful and failed remote JSON responses use [schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json) (except `operation`, which uses [schemas/hive-operation.v1.json](../schemas/hive-operation.v1.json)).
- Remote mutations accept `--idempotency-key KEY` (auto-generating a 64-hex key if omitted). When a response is lost in transit, Hive reports an `unknown_submission` error carrying `idempotency_key` and `target` so the caller can safely replay the exact request with `--idempotency-key`.
- All other visible commands are `local_only` and exit `64` before runtime activation or network I/O.

## Exit Codes

| Code | Constant | Meaning |
|---:|---|---|
| `0` | `SUCCESS` | Command completed cleanly. |
| `1` | `GENERIC` | Generic or command-specific non-zero outcome (for example daemon/bot not running, queue entry not found, `version` serialization failure before output, or `setup-agents` residual failure). |
| `2` | `ALREADY_INITIALIZED` | Target project is already initialized (`hive init` without `--force`). |
| `3` | `TASK_IN_ERROR` | Target task carries an error marker (`ERROR` / `REVIEW_ERROR`). |
| `4` | `WRONG_STAGE` | Task is not in an eligible stage or marker check failed (`markers clear`). |
| `20` | `COMMAND_CONFLICT` | Durable receipt / idempotency conflict. |
| `21` | `COMMAND_IN_PROGRESS` | Durable receipt command is still in progress. |
| `22` | `COMMAND_UNRESOLVED` | Durable receipt outcome is unresolved and requires operator reconciliation. |
| `64` | `USAGE` | Malformed invocation, unsupported option/context combination, unknown target, or missing explicit consent (`--yes` / `--confirm` / `--force`). |
| `65` | — | `hive doctor`: at least one available managed skill or required dependency is actionable. |
| `69` | `UNAVAILABLE` | Required remote transport or dependency unavailable. |
| `70` | `SOFTWARE` | Internal, git, worktree, service-manager, stage, or agent execution failure. |
| `75` | `TEMPFAIL` | Transient contention, lock/PID conflict, quiesce/resume timeout, or busy retryable condition. |
| `78` | `CONFIG` | Invalid project/global configuration, manifest, or schema-upgrade precondition. |

Historical state conversion is an offline agent task; see [docs/guides/current-format-migration.md](guides/current-format-migration.md).

## Command Catalog

### `hive accept-finding`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive accept-finding TARGET [ID...]`
- **Options:** `--project`, `--stage`, `--pass`, `--severity`, `--all`, `--json`, `--context`
- **Output:** Text summary of toggled review findings, or single-document JSON (`hive-findings.v1`, [schemas/hive-findings.v1.json](../schemas/hive-findings.v1.json)) on success and error. Serialization failure policy is `:raise` (no fallback JSON).
- **Context behavior:** Local only; under a remote context preflight exits `64` with `accept-finding requires a local context; specify --context local`.
- **Exits and retry:** `0` toggled (idempotent for already-accepted IDs), `64` invalid target/selector/options, `70` internal/file error, `75` task lock contention (retryable).
- **Effects and approvals:** Mutates GFM checkboxes to `[x]` in the selected `reviews/ce-review-NN.md` under the task lock; no interactive prompt.
- **Example:** `hive accept-finding my-task 1 3 --json`

### `hive act`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive act ACTION_ID TARGET`
- **Options:** `--project`, `--observation`, `--confirm`, `--idempotency-key`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON: locally emits `hive-act.v2` ([schemas/hive-act.v2.json](../schemas/hive-act.v2.json)) on success and error; if error-envelope serialization raises `JSON::GeneratorError`, that generator exception is raised rather than suppressed and no fallback JSON document is emitted (`:raise`). Remotely emits `hive-remote.v1` ([schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json)).
- **Context behavior:** Local accepts `--project`, `--observation`, `--confirm`, and `--idempotency-key`. Remote requires `--observation TOKEN` from fresh remote status or task details, accepts `--project` and `--idempotency-key` (rejecting `--confirm` with exit `64`), and POSTs `/actions`.
- **Exits and retry:** `0` action executed/admitted, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` missing/stale observation, confirmation required, or bad usage, `69`/`75` transient remote/lock failure (replay lost remote response with the reported `idempotency_key` and `target`), `70` execution failure, `78` config error.
- **Effects and approvals:** Dispatches or commits the named operational action against `TARGET`; confirmation-gated actions require `--confirm` locally and fresh `--observation` binding.
- **Example:** `hive act workflow.retry demo:my-task --observation obs_abc123 --json`

### `hive answer`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive answer TARGET`
- **Modes:**
  - **Mode `inventory`** (condition: `without --binding`; options: `--project`, `--json`, `--context`): Read-only inventory of pending brainstorm questions and binding tokens for `TARGET`.
  - **Mode `write`** (condition: `--binding TOKEN`; options: `--project`, `--binding`, `--idempotency-key`, `--json`, `--context`): Persists one identity-bound answer read from stdin (up to 64 KiB non-blank UTF-8).
- **Options:** `--project`, `--binding`, `--idempotency-key`, `--json`, `--context`
- **Output:** Text inventory/acknowledgement, or single-document JSON: locally `hive-answer.v1` ([schemas/hive-answer.v1.json](../schemas/hive-answer.v1.json)) on success and error; remotely `hive-remote.v1` ([schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json)).
- **Context behavior:** Local reads or writes brainstorm questions directly in task state. Remote GETs `/questions` in `inventory` mode and POSTs `/answers` with stdin text and `--idempotency-key` in `write` mode.
- **Exits and retry:** `0` inventory read or answer recorded, `20`/`21`/`22` receipt conflict/in-progress/unresolved, `64` invalid target, stale binding token, or empty/oversized stdin, `69`/`75` transient transport or lock contention (safe to replay with the same `--idempotency-key`), `70` internal error.
- **Effects and approvals:** `inventory` is read-only. `write` appends the answer and updates question markers under task locking; binding token prevents stale-question overwrite.
- **Example:** `printf 'Option B\n' | hive answer demo:my-task --binding tok_123 --idempotency-key ans-1 --json`

### `hive answer-digest`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive answer-digest`
- **Options:** `--dry-run`, `--date`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-answer-digest.v1`, [schemas/hive-answer-digest.v1.json](../schemas/hive-answer-digest.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64` with `answer-digest requires a local context; specify --context local`.
- **Exits and retry:** `0` digest sent or dry-run computed (idempotent per date once delivered), `64` invalid `--date` or usage, `70` delivery/internal error, `78` malformed Telegram/global config.
- **Effects and approvals:** Without `--dry-run`, sends a Telegram digest of tasks waiting on human input and records delivery state; `--dry-run` performs no send or state write.
- **Example:** `hive answer-digest --dry-run --json`

### `hive approve`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive approve TARGET`
- **Options:** `--from`, `--to`, `--force`, `--project`, `--generation`, `--idempotency-key`, `--json`, `--context`
- **Output:** Text transition summary, or single-document JSON: locally `hive-approve.v2` ([schemas/hive-approve.v2.json](../schemas/hive-approve.v2.json)) on success and error (`:raise` serialization policy); remotely `hive-remote.v1` ([schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json)).
- **Context behavior:** Local rejects `--generation` before runtime with exit `64` (`--generation requires --context <remote>; local approvals use --from`) and supports `--from`, `--to`, `--force`, `--project`, and `--idempotency-key`. Remote accepts `--project`, `--from`, `--generation`, and `--idempotency-key` (rejecting `--to` and `--force` with exit `64`); without `read` scope both `--from` and `--generation` are required, whereas with `read` scope missing values are fetched from task details before POSTing `/approvals`.
- **Exits and retry:** `0` approved/moved, `3` task in error without `--force`, `4` wrong stage / `--from` mismatch, `20`/`21`/`22` receipt conflict/in-progress/unresolved, `64` invalid stage, local `--generation`, or missing remote `--from`/`--generation`, `69`/`75` transient remote/lock failure (on a lost remote response, exits `75` and prints `approval replay --from STAGE --generation GENERATION --idempotency-key KEY` on stderr plus `idempotency_key`/`target` in JSON so callers can replay safely even after advancement), `70` git/storage error.
- **Effects and approvals:** Moves `TARGET` to the next workflow stage (or local `--to <stage>`) and commits state; `--force` overrides local error-marker/completion guards.
- **Example:** `hive approve demo:my-task --from 3-plan --idempotency-key appr-42 --json`

### `hive archive`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive archive [TARGET]`
- **Modes:**
  - **Mode `list`** (condition: `no TARGET`; options: `--project`, `--from`, `--json`, `--context`): Read-only listing of `9-done` tasks across registered projects (or filtered by `--project`).
  - **Mode `stage_action`** (condition: `TARGET without closure options`; options: `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`): Moves a completed finalize task into `9-done` through the stage-action pipeline.
  - **Mode `closure_preview`** (condition: `TARGET with --reason and --json without --yes`; options: `--from`, `--project`, `--reason`, `--evidence`, `--successor`, `--attestation`, `--json`, `--context`): Read-only evidence-closure preview emitting `hive-task-closure-input.v1` with `mode: "preview"`, `applied: false`, and the exact `next` command.
  - **Mode `closure_apply`** (condition: `TARGET with --reason and --yes or TTY confirmation`; options: `--from`, `--project`, `--reason`, `--evidence`, `--successor`, `--attestation`, `--yes`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`): Applies evidence-backed closure and moves `TARGET` to `9-done`, recording a closure receipt.
- **Options:** `--project`, `--from`, `--reason`, `--evidence`, `--successor`, `--attestation`, `--yes`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Single-document JSON per mode: `stage_action` uses `hive-stage-action.v2` ([schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json), `:raise`); `closure_preview` uses `hive-task-closure-input.v1` ([schemas/hive-task-closure-input.v1.json](../schemas/hive-task-closure-input.v1.json)); `closure_apply` uses `hive-task-closure-result.v1` ([schemas/hive-task-closure-result.v1.json](../schemas/hive-task-closure-result.v1.json)); `list` emits JSON array/summary or text list.
- **Context behavior:** Local only; remote context exits `64` with `archive requires a local context; specify --context local`.
- **Exits and retry:** `0` listed, previewed, or archived, `3` task in error, `4` wrong stage, `20`/`21`/`22` receipt conflict/in-progress/unresolved, `64` invalid closure flags or missing `--yes` in non-TTY apply, `70` stage/git error, `75` lock contention.
- **Effects and approvals:** `list` and `closure_preview` are read-only. `stage_action` and `closure_apply` move the task to `9-done` and commit state; closure requires `--reason` plus `--yes` or TTY confirmation.
- **Example:** `hive archive my-task --reason "superseded" --evidence pr=42 --yes --json`

### `hive artifacts`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive artifacts TARGET`
- **Options:** `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64` with `artifacts requires a local context; specify --context local`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` invalid target/options, `70` stage/agent failure, `75` lock contention (retryable with `--idempotency-key`).
- **Effects and approvals:** Promotes a completed `6-review` task into `7-artifacts` (if not already there) and runs the artifacts stage agent in the task worktree.
- **Example:** `hive artifacts my-task --from 6-review --json`

### `hive babysit`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit`
  - `hive babysit --once PROJECT`
  - `hive babysit --once --all`
- **Modes:**
  - **Mode `missing_subcommand`** (condition: `no SUBCOMMAND and no --once`; options: `--json`, `--context`): Fails with usage error (`64`) directing callers to a named subcommand or `--once`.
  - **Mode `once_project`** (condition: `--once PROJECT without named SUBCOMMAND`; options: `--once`, `--dry-run`, `--json`, `--context`): Runs one bounded PR babysitter pass for `PROJECT` and emits `hive-one-shot.v1`.
  - **Mode `once_all`** (condition: `--once --all without named SUBCOMMAND`; options: `--once`, `--all`, `--dry-run`, `--json`, `--context`): Runs one bounded PR babysitter pass across every enabled project and emits `hive-one-shot.v1`.
- **Options:** `--once`, `--all`, `--dry-run`, `--json`, `--context`
- **Output:** `once_project` and `once_all` always emit single-document JSON (`hive-one-shot.v1`, [schemas/hive-one-shot.v1.json](../schemas/hive-one-shot.v1.json)). `missing_subcommand` prints usage guidance to stderr.
- **Context behavior:** Local only; remote context exits `64` with `babysit requires a local context; specify --context local`.
- **Exits and retry:** `0` one-shot pass settled cleanly, `64` missing subcommand or invalid `--once` target, `70` internal failure, `75` live babysitter/one-shot owner conflict or partial failure (retryable when owner exits), `78` config error.
- **Effects and approvals:** One-shot passes honor installation quiescence and may dispatch PR repair agents for enabled projects unless `--dry-run` is set.
- **Example:** `hive babysit --once my-project --dry-run`

### `hive babysit install`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit install [--force]`
- **Options:** `--force`, `--json`, `--context`
- **Output:** Human-readable text reporting platform-native service installation outcome; `--json` is ignored for named babysit subcommands.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` installed/upgraded/unchanged/unsupported-manager, `64` existing drifted unit without `--force` (retry with `--force`), `70` service-manager failure.
- **Effects and approvals:** Writes and enables the per-user systemd/launchd babysitter unit; with `--force` saves a timestamped `.bak` copy before overwriting and restarts the service.
- **Example:** `hive babysit install --force`

### `hive babysit reload`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit reload`
- **Options:** `--json`, `--context`
- **Output:** Human-readable text; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` SIGHUP sent, `1` babysitter not running, `64` invalid flags (forbids `--once`/`--all`).
- **Effects and approvals:** Signals the running babysitter process with `SIGHUP` to reload config/log settings.
- **Example:** `hive babysit reload`

### `hive babysit restart`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit restart [--detach] [--dry-run]`
- **Options:** `--detach`, `--dry-run`, `--json`, `--context`
- **Output:** Human-readable text; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` restarted cleanly, `64` invalid flags, `70` internal error, `75` live PID conflict after stop.
- **Effects and approvals:** Stops any running babysitter and starts a fresh loop (foreground or `--detach`); `--dry-run` suppresses side-effecting PR repairs.
- **Example:** `hive babysit restart --detach`

### `hive babysit start`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit start [--detach] [--dry-run]`
- **Options:** `--detach`, `--dry-run`, `--json`, `--context`
- **Output:** Human-readable text; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` started (detached) or exited cleanly (foreground), `64` invalid flags, `75` another babysitter is already running.
- **Effects and approvals:** Runs the PR babysitter loop across projects with `babysitter.enabled: true` and writes its PID file; `--dry-run` enables side-effect guards.
- **Example:** `hive babysit start --detach --dry-run`

### `hive babysit status`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit status`
- **Options:** `--json`, `--context`
- **Output:** Human-readable running/not-running status; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` babysitter running, `1` babysitter not running, `64` invalid flags.
- **Effects and approvals:** Read-only PID probe.
- **Example:** `hive babysit status`

### `hive babysit stop`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit stop`
- **Options:** `--json`, `--context`
- **Output:** Human-readable text; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` stopped or already not running (idempotent), `64` invalid flags, `70` internal error.
- **Effects and approvals:** Sends `SIGTERM` to the running babysitter PID and cleans stale PID state.
- **Example:** `hive babysit stop`

### `hive babysit tail`

- **Aliases:** none
- **Support:** `experimental`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive babysit tail`
- **Options:** `--json`, `--context`
- **Output:** Streams `babysitter.log` lines to stdout; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` stream ended by Ctrl-C, `1` log file absent, `64` invalid flags.
- **Effects and approvals:** Read-only log follower.
- **Example:** `hive babysit tail`

### `hive bench submit`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bench submit SLUG`
- **Options:** `--project`, `--json`, `--context`
- **Output:** Text PR URL/summary, or success-only schema-less JSON (`--json` emits a JSON result object on success; failures print diagnostics on stderr with no JSON error envelope).
- **Context behavior:** Local only; remote context exits `64` with `bench requires a local context; specify --context local`.
- **Exits and retry:** `0` corpus entry extracted and PR opened, `64` missing/ambiguous `9-done` task, missing `HIVE_BENCH_PATH`, secret/PII preflight hit, or git/`gh` failure.
- **Effects and approvals:** Runs a local secret/PII scan, extracts the completed task into the `hive-bench` checkout, commits a branch, and opens a GitHub PR via `gh`.
- **Example:** `hive bench submit my-done-task --project demo`

### `hive bot`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot`
- **Options:** `--json`, `--context`
- **Output:** Usage error text on stderr (or JSON error envelope when `--json` is passed for missing subcommand).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND` (`start`, `stop`, `status`, `reload`, `tail`, `install`).
- **Effects and approvals:** No side effects.
- **Example:** `hive bot status`

### `hive bot install`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot install [--force] [--json]`
- **Options:** `--force`, `--json`, `--context`
- **Output:** Human-readable text, or single-document JSON (`hive-bot-install.v1`, [schemas/hive-bot-install.v1.json](../schemas/hive-bot-install.v1.json)) reporting `outcome` (`written`, `upgraded`, `unchanged`, `unsupported`, `drifted`, `failed`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` written/upgraded/unchanged/unsupported, `64` drifted existing unit without `--force` (retry with `--force`), `70` service-manager failure, `78` missing/invalid global bot config.
- **Effects and approvals:** Writes and enables the opt-in per-user Telegram bot service unit; `--force` backs up the previous unit to `<path>.bak-<UTC-stamp>` and restarts the running bot.
- **Example:** `hive bot install --force --json`

### `hive bot reload`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot reload [--json]`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-bot-reload.v1`, [schemas/hive-bot-reload.v1.json](../schemas/hive-bot-reload.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` SIGHUP sent, `1` bot not running, `70` internal error, `78` bad global bot config.
- **Effects and approvals:** Signals the running Telegram bot with `SIGHUP` to reload config.
- **Example:** `hive bot reload --json`

### `hive bot start`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot start [--foreground] [--dry-run]`
- **Options:** `--foreground`, `--dry-run`, `--json`, `--context`
- **Output:** Human-readable startup/log output; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` started in background or foreground loop exited cleanly, `70` internal error, `75` live bot already running, `78` missing `HIVE_TELEGRAM_BOT_TOKEN` or invalid global `bot:` config.
- **Effects and approvals:** Starts the Telegram long-poll bot (backgrounded by default, or foreground with `--foreground`); `--dry-run` suppresses spawning child Hive commands.
- **Example:** `hive bot start --foreground --dry-run`

### `hive bot status`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot status [--json]`
- **Options:** `--json`, `--context`
- **Output:** Running/not-running text, or single-document JSON (`hive-bot-status.v1`, [schemas/hive-bot-status.v1.json](../schemas/hive-bot-status.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` bot running, `1` bot not running, `70` internal error.
- **Effects and approvals:** Read-only PID and unit probe.
- **Example:** `hive bot status --json`

### `hive bot stop`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot stop [--json]`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-bot-stop.v1`, [schemas/hive-bot-stop.v1.json](../schemas/hive-bot-stop.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` stopped or already not running (idempotent), `70` internal error.
- **Effects and approvals:** Sends `SIGTERM` to the running Telegram bot and cleans stale PID state.
- **Example:** `hive bot stop --json`

### `hive bot tail`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive bot tail`
- **Options:** `--json`, `--context`
- **Output:** Streams `bot.log` lines; `--json` is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` stream ended by Ctrl-C, `1` log file does not exist.
- **Effects and approvals:** Read-only log follower.
- **Example:** `hive bot tail`

### `hive brainstorm`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive brainstorm TARGET`
- **Options:** `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` invalid target/options, `70` stage/agent failure, `75` lock contention.
- **Effects and approvals:** Promotes an `1-inbox` task into `2-brainstorm` (if not already there) and runs the brainstorm stage agent.
- **Example:** `hive brainstorm my-task --from 1-inbox --json`

### `hive connect screenote`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive connect screenote`
- **Options:** `--base-url`, `--json`, `--context`
- **Output:** Interactive text flow, or schema-less JSON Lines (`--json` streams an `authorize` JSON line carrying `authorize_url`, followed by a final success line with `issuer`, `client_id`, `project_id`, `base_url`, and `credential_path`, or an error line such as `needs_project_selection`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` credential stored, `1` OAuth timeout (300s loopback window), `needs_project_selection` in non-interactive `--json`, or network/OS error, `64` unsupported service or bad URL.
- **Effects and approvals:** Opens browser OAuth 2.1 + PKCE loopback redirect, queries Screenote MCP projects, prompts interactively if multiple projects exist, and writes `~/.config/hive/screenote.json` (`0600`).
- **Example:** `hive connect screenote --json`

### `hive context`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Context#validate_options! allowlist (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/context.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#context help (R12)`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive context`
- **Options:** `--json`, `--context`
- **Output:** Defaults to `context list`: text table of configured contexts (`local` plus saved remotes), or single-document JSON (`hive-context.v1`, [schemas/hive-context.v1.json](../schemas/hive-context.v1.json)) on success and error.
- **Context behavior:** Always executes client-side before local Hive setup, even when a remote context is active.
- **Exits and retry:** `0` listed, `64` invalid options, `78` malformed contexts configuration.
- **Effects and approvals:** Read-only client configuration inspection.
- **Example:** `hive context --json`

### `hive context add`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Context#validate_options! allowlist (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/context.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#context help (R12)`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive context add NAME --url URL --token-stdin`
- **Options:** `--url`, `--token-stdin`, `--json`, `--context`
- **Output:** Text summary showing verified instance metadata, scopes, project limits, and expiry, or single-document JSON (`hive-context.v1`, [schemas/hive-context.v1.json](../schemas/hive-context.v1.json)) on success and error.
- **Context behavior:** Always executes client-side; contacts the target HTTPS installation to verify the bearer token supplied on stdin. Never accepts a bearer as a CLI argument.
- **Exits and retry:** `0` context verified and saved, `64` reserved/invalid `NAME`, missing `--url`/`--token-stdin`, or invalid token format, `69` remote endpoint unreachable/rejected, `78` config/storage error.
- **Effects and approvals:** Reads the bearer token from stdin, verifies it over HTTPS, and stores the context and private credential in local client config.
- **Example:** `printf '%s\n' "$HIVE_TOKEN" | hive context add prod --url https://hive.example --token-stdin --json`

### `hive context list`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Context#validate_options! allowlist (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/context.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#context help (R12)`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive context list`
- **Options:** `--json`, `--context`
- **Output:** Text table of `local` and saved remote contexts showing active selection, or single-document JSON (`hive-context.v1`, [schemas/hive-context.v1.json](../schemas/hive-context.v1.json)).
- **Context behavior:** Always executes client-side regardless of active `--context`.
- **Exits and retry:** `0` listed, `64` unexpected positional `NAME` or creation-only flags, `78` malformed client config.
- **Effects and approvals:** Read-only.
- **Example:** `hive context list --json`

### `hive context show`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Context#validate_options! allowlist (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/context.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#context help (R12)`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive context show [NAME]`
- **Options:** `--json`, `--context`
- **Output:** Text details (fresh scopes, project limits, expiry for remote targets, or unrestricted local operator authority for `local`), or single-document JSON (`hive-context.v1`, [schemas/hive-context.v1.json](../schemas/hive-context.v1.json)).
- **Context behavior:** Always executes client-side; queries the remote installation for fresh token metadata when inspecting a remote context.
- **Exits and retry:** `0` shown, `64` unknown context name or invalid flags, `69` remote verification failed, `78` malformed client config.
- **Effects and approvals:** Read-only.
- **Example:** `hive context show prod --json`

### `hive context use`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Context#validate_options! allowlist (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/context.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#context help (R12)`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive context use NAME`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation with fresh context metadata, or single-document JSON (`hive-context.v1`, [schemas/hive-context.v1.json](../schemas/hive-context.v1.json)).
- **Context behavior:** Always executes client-side; verifies remote contexts before updating the default client selection.
- **Exits and retry:** `0` default context updated, `64` missing/unknown `NAME` or invalid flags, `69` remote verification failed, `78` config write error.
- **Effects and approvals:** Updates the saved active context in client configuration (`local` or named remote).
- **Example:** `hive context use local --json`

### `hive daemon`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon`
- **Modes:**
  - **Mode `missing_subcommand`** (condition: `no SUBCOMMAND and no --once`; options: `--json`, `--context`): Exits `64` with usage guidance listing valid daemon subcommands.
  - **Mode `once`** (condition: `--once PROJECT without named SUBCOMMAND`; options: `--once`, `--dry-run`, `--json`, `--context`): Runs one project-scoped dispatch admission round, drains owned durable work (4-hour drain window), reconciles completions and module hooks, honors installation quiescence, and emits `hive-one-shot.v1` ([schemas/hive-one-shot.v1.json](../schemas/hive-one-shot.v1.json)). Passing `--once` together with a named daemon subcommand is rejected (`64`).
- **Options:** `--once`, `--dry-run`, `--json`, `--context`
- **Output:** Mode `once` always emits single-document JSON (`hive-one-shot.v1`, [schemas/hive-one-shot.v1.json](../schemas/hive-one-shot.v1.json)). Mode `missing_subcommand` reports usage error on stderr. On command-level error-envelope `JSON::GeneratorError`, daemon warns on stderr, emits no substitute document, and re-raises (`:warn`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` one-shot pass settled cleanly, `64` missing or unknown subcommand or conflicting `--once` + subcommand, `70` internal error, `75` live daemon/one-shot owner refusal or drain timeout (retryable once owner settles), `78` config error.
- **Effects and approvals:** Mode `once` dispatches ready workflow tasks and reconciles durable completions for `PROJECT` unless `--dry-run` is passed.
- **Example:** `hive daemon --once my-project --dry-run`

### `hive daemon clear-hold`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon clear-hold PROJECT [SLUG]`
- **Options:** `--json`, `--context`
- **Output:** Text-only confirmation; explicitly rejects `--json` (as well as `--all`, `--dry-run`, `--detach`) with exit `64`.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` named hold or quarantine cleared, or no matching hold existed (idempotent), `64` missing/unknown `PROJECT`, extra arguments, or unsupported mode flag (`--json`), `75` daemon PID file still exists (stop/clean with `hive daemon stop` first, then retry).
- **Effects and approvals:** Clears the persisted dropped-project hold for `PROJECT` (or only `SLUG`'s task quarantine) while the daemon is stopped under the activation lock.
- **Example:** `hive daemon clear-hold my-project stuck-task`

### `hive daemon disable`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon disable PROJECT [--json]`
  - `hive daemon disable --all [--json]`
- **Options:** `--all`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-daemon-enroll.v1`, [schemas/hive-daemon-enroll.v1.json](../schemas/hive-daemon-enroll.v1.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` every selected project updated (idempotent), `64` missing/unknown/uninitialised project, conflicting `PROJECT` + `--all`, or no registered projects, `70` unexpected internal failure, `78` malformed project/global `config.yml` or unsupported inline-flow / non-2-space `daemon:` YAML block.
- **Effects and approvals:** Atomically sets `daemon.enabled: false` in each selected project's `.hive-state/config.yml` after preflighting all targets; in-flight children finish unaffected.
- **Example:** `hive daemon disable my-project --json`

### `hive daemon enable`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon enable PROJECT [--json]`
  - `hive daemon enable --all [--json]`
- **Options:** `--all`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-daemon-enroll.v1`, [schemas/hive-daemon-enroll.v1.json](../schemas/hive-daemon-enroll.v1.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` every selected project updated (idempotent), `64` missing/unknown/uninitialised project, conflicting `PROJECT` + `--all`, or no registered projects, `70` unexpected internal failure, `78` malformed `config.yml` or unsupported YAML layout.
- **Effects and approvals:** Atomically sets `daemon.enabled: true` in each selected project's `.hive-state/config.yml` without installing or starting the global daemon service.
- **Example:** `hive daemon enable --all --json`

### `hive daemon install`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon install [--force] [--json]`
- **Options:** `--force`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-daemon-install.v1`, [schemas/hive-daemon-install.v1.json](../schemas/hive-daemon-install.v1.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`. Managed service definitions pin `--context local` so a saved remote context never interrupts the local daemon.
- **Exits and retry:** `0` installed, upgraded, unchanged, or written on a host without a usable user service manager, `64` existing drifted unit requires `--force` or invalid arguments (retry with `--force`), `70` service-manager or internal installation failure.
- **Effects and approvals:** Writes and enables the per-user systemd/launchd daemon unit; `--force` backs up the existing file to `<path>.bak-<UTC-stamp>` and restarts the running daemon.
- **Example:** `hive daemon install --force --json`

### `hive daemon queue`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon queue`
- **Options:** `--json`, `--context`
- **Output:** Defaults to `daemon queue list`: text table of pending dispatch requests, or single-document JSON (`hive-daemon-queue.v1`, [schemas/hive-daemon-queue.v1.json](../schemas/hive-daemon-queue.v1.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed (empty queue is success), `64` unknown queue action, `70` internal IO/parse error (matching `error_kind: "internal"` in JSON).
- **Effects and approvals:** Read-only inspection of runtime SQL dispatch-request queue (`hive-dispatch-request.v5`).
- **Example:** `hive daemon queue --json`

### `hive daemon queue list`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon queue list`
- **Options:** `--json`, `--context`
- **Output:** Text table of pending dispatch requests with age and verb, or single-document JSON (`hive-daemon-queue.v1`, [schemas/hive-daemon-queue.v1.json](../schemas/hive-daemon-queue.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` always on valid store (empty queue is success), `64` invalid queue arguments, `70` internal IO/parse error.
- **Effects and approvals:** Read-only.
- **Example:** `hive daemon queue list --json`

### `hive daemon queue prune`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon queue prune`
- **Options:** `--json`, `--context`
- **Output:** Text count of pruned expired/malformed entries, or single-document JSON (`hive-daemon-queue.v1`, [schemas/hive-daemon-queue.v1.json](../schemas/hive-daemon-queue.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` always on valid store (idempotent), `64` invalid queue arguments, `70` internal IO/parse error.
- **Effects and approvals:** Removes expired or malformed queue entries while preserving non-terminal recovery requests and bounded terminal receipts.
- **Example:** `hive daemon queue prune --json`

### `hive daemon queue show`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon queue show <id>`
- **Options:** `--json`, `--context`
- **Output:** Detailed text dump of one dispatch request, or single-document JSON (`hive-daemon-queue.v1`, [schemas/hive-daemon-queue.v1.json](../schemas/hive-daemon-queue.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` request found, `1` request not found, `64` missing `REQUEST_ID` or invalid arguments, `70` internal IO/parse error.
- **Effects and approvals:** Read-only.
- **Example:** `hive daemon queue show req_123 --json`

### `hive daemon quiesce`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon quiesce [--timeout SECONDS]`
- **Options:** `--timeout`, `--json`, `--context`
- **Output:** Text status, or single-document JSON (`hive-daemon-quiesce.v1`, [schemas/hive-daemon-quiesce.v1.json](../schemas/hive-daemon-quiesce.v1.json)) on success and error; only verified `paused: true` exits `0`, and any non-paused result after admission closes reports `resume_required: true` and `resume_command: "hive daemon resume"`.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` verified paused acknowledgement with generation-bound proof, `64` invalid `--timeout`, `70` storage failure, `75` busy, timed out, or ownership unverifiable (retrying continues the closed generation without reopening admission), `78` schema upgrade required.
- **Effects and approvals:** Applies read-only ownership precheck, closes installation-wide admission, drains/stops owned work, checkpoints SQLite, and writes the generation-bound quiescence proof within the 600s default (or `--timeout`) deadline.
- **Example:** `hive daemon quiesce --timeout 300 --json`

### `hive daemon reload`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon reload [--json]`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-daemon-reload.v1`, [schemas/hive-daemon-reload.v1.json](../schemas/hive-daemon-reload.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` SIGHUP sent successfully, `1` daemon not running (caller must start one first), `70` internal error.
- **Effects and approvals:** Sends `SIGHUP` so the running daemon validates and applies reloaded concurrency/config limits at the next tick boundary without interrupting in-flight children.
- **Example:** `hive daemon reload --json`

### `hive daemon resume`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon resume [--timeout SECONDS]`
- **Options:** `--timeout`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-daemon-resume.v1`, [schemas/hive-daemon-resume.v1.json](../schemas/hive-daemon-resume.v1.json)) reporting `admission_reopened` separately from per-service restore outcomes.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` reconciliation completed and admission reopened, `64` invalid `--timeout`, `70` storage failure, `75` busy, timed out, or reconciliation incomplete (retryable), `78` supervised schema upgrade required before retrying resume.
- **Effects and approvals:** Removes the old quiescence proof, reconciles interrupted-attempt evidence under launch/writer fences, reopens installation admission, and restarts previously running managed services.
- **Example:** `hive daemon resume --timeout 300 --json`

### `hive daemon start`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon start [--detach] [--dry-run]`
- **Options:** `--detach`, `--dry-run`, `--json`, `--context`
- **Output:** Human-readable startup/log output; `--json` warns on stderr and is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` foreground daemon exited cleanly or detached parent returned after handoff, `64` invalid flags, `70` readiness publication or internal failure, `75` another live daemon already holds the PID file.
- **Effects and approvals:** Acquires the daemon-activation lock, writes the PID file, pins `HIVE_BIN`, and runs the auto-advancing dispatcher loop (or logs decisions only with `--dry-run`).
- **Example:** `hive daemon start --detach --dry-run`

### `hive daemon status`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon status [--json]`
- **Options:** `--json`, `--context`
- **Output:** Running/not-running text, or single-document JSON (`hive-daemon-status.v1`, [schemas/hive-daemon-status.v1.json](../schemas/hive-daemon-status.v1.json)) carrying `runtime`, `running`, `pid`, `uptime_sec`, `service_installed`, `service_enabled`, `unit_path`, `runtime_installation`, `lifecycle`, `quiescence_capability`, and `binary_drift`.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` daemon is running, `1` daemon is not running (scriptable precondition probe), `70` internal error.
- **Effects and approvals:** Strictly read-only observation; remains available across schema skew and never migrates, signals, or repairs state.
- **Example:** `hive daemon status --json`

### `hive daemon stop`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon stop [--json]`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-daemon-stop.v1`, [schemas/hive-daemon-stop.v1.json](../schemas/hive-daemon-stop.v1.json)) carrying `running`, `was_running`, and optional `stale_pid`/`reason`.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` always (idempotent when daemon is already stopped or PID file is stale), `70` unexpected internal failure.
- **Effects and approvals:** Sends `SIGTERM` to the running daemon, waits up to `daemon.shutdown_grace_sec` (default 600s) before `SIGKILL`, and cleans stale PID state.
- **Example:** `hive daemon stop --json`

### `hive daemon tail`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive daemon tail`
- **Options:** `--json`, `--context`
- **Output:** Streams `daemon.log` with `tail -F` semantics; `--json` warns on stderr and is ignored.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` stream ended via Ctrl-C, `1` log file does not exist.
- **Effects and approvals:** Read-only log follower.
- **Example:** `hive daemon tail`

### `hive decide`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive decide TARGET OUTCOME --from FROM`
- **Options:** `--from`, `--decision-id`, `--note`, `--project`, `--json`, `--context`
- **Output:** Text transition confirmation, or single-document JSON (`hive-decide.v1`, [schemas/hive-decide.v1.json](../schemas/hive-decide.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` outcome applied, `4` wrong stage or stale `--decision-id` / `--from` visit mismatch, `64` invalid outcome or missing `--from`, `70` storage/git failure, `75` lock contention.
- **Effects and approvals:** Applies one workflow-descriptor-declared outcome to the observed visit of a durable human stage and advances `TARGET` accordingly.
- **Example:** `hive decide my-task approve --from approval --decision-id abcdef0123456789 --json`

### `hive develop`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive develop TARGET`
- **Options:** `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` invalid target/options, `70` stage/agent failure, `75` lock contention.
- **Effects and approvals:** Promotes a completed `3-plan` task into `4-execute` (if not already there), ensures the task worktree exists, and runs the execute stage agent.
- **Example:** `hive develop my-task --from 3-plan --json`

### `hive digest`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive digest`
- **Options:** `--date`, `--project`, `--open-web`, `--json`, `--context`
- **Output:** Text summary of today's (or `--date`) persisted host-global daily activity record, or single-document JSON (`hive-digest.v1`, [schemas/hive-digest.v1.json](../schemas/hive-digest.v1.json)) on success and error (`--json` and `--open-web` are mutually exclusive, exit `64`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` record read or opened, `64` invalid `--date`, mutually exclusive `--json` + `--open-web`, or bad arguments, `70` internal error, `78` invalid `web.origin` config when using `--open-web`.
- **Effects and approvals:** Strictly read-only (never calls Telegram, refreshes, or repairs a stale record); `--open-web` opens the selected digest URL in a browser.
- **Example:** `hive digest --date 2026-11-27 --project demo --json`

### `hive digest prune`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive digest prune --before DATE --dry-run`
  - `hive digest prune --before DATE --yes`
- **Options:** `--before`, `--dry-run`, `--yes`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-digest-prune.v1`, [schemas/hive-digest-prune.v1.json](../schemas/hive-digest-prune.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed or pruned (idempotent), `64` missing `--before`, neither/both of `--dry-run` and `--yes`, or invalid date, `70` storage error.
- **Effects and approvals:** `--dry-run` is read-only; `--yes` explicitly deletes closed digest projection records older than `DATE`.
- **Example:** `hive digest prune --before 2026-06-01 --dry-run --json`

### `hive digest refresh`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive digest refresh [--date DATE]`
- **Options:** `--date`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-digest-refresh.v1`, [schemas/hive-digest-refresh.v1.json](../schemas/hive-digest-refresh.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` refreshed (idempotent), `64` invalid `--date`, `70` storage/internal error, `75` lock contention.
- **Effects and approvals:** Recomputes and persists the host-global daily activity digest record for `DATE` (default today) without sending Telegram.
- **Example:** `hive digest refresh --date 2026-11-27 --json`

### `hive digest send`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive digest send --date DATE [--retry]`
- **Options:** `--date`, `--retry`, `--json`, `--context`
- **Output:** Text delivery confirmation, or single-document JSON (`hive-digest-send.v1`, [schemas/hive-digest-send.v1.json](../schemas/hive-digest-send.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` sent or already delivered, `64` missing/invalid `--date` or failed/unknown prior delivery without `--retry`, `70` delivery failure, `78` invalid Telegram config.
- **Effects and approvals:** Sends the persisted daily digest for `DATE` via Telegram and updates durable delivery state; `--retry` explicitly retries a failed or unknown delivery.
- **Example:** `hive digest send --date 2026-11-27 --retry --json`

### `hive disconnect screenote`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive disconnect screenote`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation, or single-document schema-less JSON (`{ "ok": true, "service": "screenote", "disconnected": ..., "revoked": ..., "reason": ... }`, plus structured error JSON on failure).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` disconnected or already absent (idempotent; revoke failures warn on stderr but still clear local credential), `1` OS/clear failure, `64` unsupported service.
- **Effects and approvals:** Attempts RFC 7009 token revocation against Screenote when a readable token exists and removes `~/.config/hive/screenote.json`.
- **Example:** `hive disconnect screenote --json`

### `hive doctor`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive doctor`
- **Options:** `--json`, `--context`
- **Output:** Human-readable diagnostic report, or single-document JSON (`hive-doctor.v2`, [schemas/hive-doctor.v2.json](../schemas/hive-doctor.v2.json)) reporting managed skill health precedence (`conflicting`, `incompatible`, `unavailable`, `stale`, `missing`, `healthy`) and required dependencies.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` all available managed skills and required dependencies are healthy, `65` at least one available managed skill or required dependency is actionable, `70` internal error, `78` malformed manifest or global config.
- **Effects and approvals:** Strictly read-only inspection; never mutates agent config or installs skills.
- **Example:** `hive doctor --json`

### `hive drop`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive drop TARGET`
- **Options:** `--from`, `--project`, `--json`, `--context`
- **Output:** Text deletion report, or single-document JSON (`hive-drop.v2`, [schemas/hive-drop.v2.json](../schemas/hive-drop.v2.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` task dropped cleanly, `4` `--from` stage mismatch, `64` unknown/ambiguous `TARGET`, `70` git/worktree/PR cleanup error, `75` lock contention.
- **Effects and approvals:** Destructively stops any live task agent, removes task folders, worktree, and local branch, and closes an associated draft PR.
- **Example:** `hive drop stale-task --project demo --json`

### `hive evidence`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive evidence`
- **Options:** `--json`, `--context`
- **Output:** Usage error on stderr naming valid evidence subcommands (`recover`, `rework`, `terminal`, `server`, `browser`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND`.
- **Effects and approvals:** No side effects.
- **Example:** `hive help evidence`

### `hive evidence browser`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive evidence browser COMMAND [ARG...]`
- **Options:** `--json`, `--context`
- **Output:** Controller-scoped agent-browser gateway response (text/JSON from the closed interaction vocabulary); inherited `--json` is ignored by the CLI wrapper.
- **Context behavior:** Local only; remote context exits `64`. Requires an active outcome-evidence producer environment.
- **Exits and retry:** `0` gateway command succeeded, `64` invoked outside producer environment or unsupported gateway command, `70` browser/gateway execution failure.
- **Effects and approvals:** Confines screenshots and recordings to the current attempt directory against the issued origin.
- **Example:** `hive evidence browser open /`

### `hive evidence recover`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive evidence recover TARGET --generation SHA256 --recovery-digest SHA256`
- **Options:** `--generation`, `--recovery-digest`, `--project`, `--stage`, `--json`, `--context`
- **Output:** Text recovery confirmation, or success-only schema-less JSON (`--json` emits a JSON summary on success; failures print diagnostics to stderr without a JSON error envelope).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` controller epoch advanced once, `64` missing/mismatched `--generation` or `--recovery-digest` or ineligible task state, `70` storage failure, `75` task lock contention.
- **Effects and approvals:** Preserves the exhausted generation, advances the controller-owned epoch once when both digests exact-match the blocked package and semantic `ERROR` marker, and instructs the operator to use generation-guarded `workflow.retry`.
- **Example:** `hive evidence recover my-task --generation <sha256> --recovery-digest <sha256> --json`

### `hive evidence rework`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive evidence rework TARGET --generation SHA256 --recovery-digest SHA256`
- **Options:** `--generation`, `--recovery-digest`, `--project`, `--stage`, `--json`, `--context`
- **Output:** Text confirmation, or success-only schema-less JSON (`--json` emits a JSON summary on success; failures print to stderr without a JSON error envelope).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` rework receipt recorded and task returned to `4-execute`, `64` missing/mismatched digests or ineligible rework pointer, `70` storage failure, `75` task lock contention.
- **Effects and approvals:** Exact-matches both digests against a reviewer-issued implementation rework pointer, records a bounded controller receipt, and moves the same task/worktree back to `4-execute`.
- **Example:** `hive evidence rework my-task --generation <sha256> --recovery-digest <sha256> --json`

### `hive evidence server`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive evidence server COMMAND -- ARGS...`
- **Options:** `--json`, `--context`
- **Output:** Text readiness/lifecycle output, or success-only JSON when `--json` is passed inside an outcome-evidence producer environment.
- **Context behavior:** Local only; remote context exits `64`. Requires an outcome-evidence producer environment.
- **Exits and retry:** `0` sandboxed server lifecycle completed cleanly, `64` outside producer environment or invalid command/separator, `70` server startup or sandbox failure.
- **Effects and approvals:** Starts one repository executable on the issued application port inside an attempt-owned credential-free sandbox and tears it down with the capture session.
- **Example:** `hive evidence server start -- bin/rails server`

### `hive evidence terminal`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive evidence terminal NAME -- COMMAND...`
- **Options:** `--json`, `--context`
- **Output:** Text recording summary, or success-only JSON when `--json` is passed inside an outcome-evidence producer environment.
- **Context behavior:** Local only; remote context exits `64`. Requires an outcome-evidence producer environment.
- **Exits and retry:** `0` recording saved, `64` outside producer environment or invalid recording name/argv, `70` recording/command failure.
- **Effects and approvals:** Runs one argv command inside the attempt environment and records `<NAME>.cast` plus a bounded plain-text review artifact.
- **Example:** `hive evidence terminal smoke -- bin/test test/unit/cli_test.rb`

### `hive finalize`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive finalize TARGET`
- **Options:** `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` invalid target/options, `70` stage/GitHub/agent failure, `75` lock contention.
- **Effects and approvals:** Promotes a completed `7-artifacts` task into `8-finalize` (if not already there), refreshes the PR body, and marks the draft PR ready for review.
- **Example:** `hive finalize my-task --from 7-artifacts --json`

### `hive findings`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive findings TARGET`
- **Options:** `--project`, `--stage`, `--pass`, `--json`, `--context`
- **Output:** Text list of review findings with checkbox state and severity, or single-document JSON (`hive-findings.v1`, [schemas/hive-findings.v1.json](../schemas/hive-findings.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` findings listed, `64` unknown task or missing review pass, `70` file/parse error.
- **Effects and approvals:** Read-only inspection of `reviews/ce-review-NN.md`.
- **Example:** `hive findings my-task --json`

### `hive forget`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive forget NAME`
- **Options:** `--if-exists`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-forget.v1`, [schemas/hive-forget.v1.json](../schemas/hive-forget.v1.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` removed (or already absent with `--if-exists`), `64` unknown project without `--if-exists` or invalid name, `70` internal error, `78` malformed global registry config.
- **Effects and approvals:** Removes `NAME` from the global project registry without deleting repository files or `.hive-state/`.
- **Example:** `hive forget old-project --if-exists --json`

### `hive generate-name`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive generate-name TARGET`
- **Options:** `--project`, `--stage`, `--json`, `--context`
- **Output:** Plain-text display name printed to stdout; `--json` is ignored (text-only).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` name generated and persisted, `64` unknown/ambiguous `TARGET`, `70` provider or storage failure.
- **Effects and approvals:** Generates and persists a human-readable display name in the target task's metadata.
- **Example:** `hive generate-name my-task --project demo`

### `hive help`

- **Aliases:** `--help`, `-?`, `-D`, `-h`
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive help [COMMAND]`
- **Options:** `--json`, `--context`
- **Output:** Human-readable Thor command list or command-specific usage/options help; `--json` is ignored (text-only).
- **Context behavior:** Runs client-side regardless of active `--context`; works before local Hive setup (`help context`, `help token`, and `help operation` are handled through client preflight without runtime activation).
- **Exits and retry:** `0` help printed, `1`/`64` unknown command name.
- **Effects and approvals:** Read-only; never dispatches `COMMAND`.
- **Example:** `hive help status`

### `hive init`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive init [PROJECT_PATH]`
- **Modes:**
  - **Mode `standard`** (condition: `without --preview`; options: `--force`, `--workflow`, `--new-workflow`, `--minimal`, `--refactor-patrol`, `--json`, `--context`): Bootstraps `.hive-state` on the orphan `hive/state` branch, registers the project, and prompts interactively on TTY for workflow/agents/daemon enrollment unless flags specify them.
  - **Mode `minimal_preview`** (condition: `--new-workflow ID --minimal --preview`; options: `--new-workflow`, `--minimal`, `--preview`, `--json`, `--context`): Read-only resolution and disclosure of fresh-project minimal initialization (`hive-init-preview.v1`) without writing files, registration, hooks, services, or timers.
- **Options:** `--force`, `--workflow`, `--new-workflow`, `--minimal`, `--preview`, `--refactor-patrol`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON: `standard` mode emits `hive-init.v3` ([schemas/hive-init.v3.json](../schemas/hive-init.v3.json)); `minimal_preview` mode emits `hive-init-preview.v1` ([schemas/hive-init-preview.v1.json](../schemas/hive-init-preview.v1.json)). Serialization failure policy is `:raise` (no fallback JSON).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` initialized or previewed, `2` project already initialized without `--force`, `64` invalid flag combination (e.g., `--preview` without `--minimal` or `--refactor-patrol` on an already-initialized project), `70` git/storage error, `78` config error.
- **Effects and approvals:** `minimal_preview` is read-only. `standard` creates the orphan `hive/state` branch, `.hive-state` worktree, LLM wiki scaffolding, and global registration (prompting on TTY for daemon enrollment and MCP import when applicable).
- **Example:** `hive init --new-workflow custom --minimal --preview --json`

### `hive markers clear`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive markers clear FOLDER --name <NAME>`
- **Options:** `--name`, `--project`, `--match-attr`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-markers-clear.v1`, [schemas/hive-markers-clear.v1.json](../schemas/hive-markers-clear.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` recovery marker removed, `4` marker absent, `--match-attr` mismatch, or marker name outside the recovery allowlist (`REVIEW_STALE`, `REVIEW_CI_STALE`, `REVIEW_ERROR`, `EXECUTE_STALE`, `ERROR`), `64` unknown subcommand or unknown task, `70` internal error, `75` task lock contention.
- **Effects and approvals:** Removes only an allowlisted recovery marker from the task state file under the task lock; terminal-success markers cannot be cleared this way. `--match-attr KEY=VALUE[,...]` prevents clearing a newer marker than the observed one.
- **Example:** `hive markers clear my-task --name ERROR --match-attr marker_id=abc123 --json`

### `hive mcp`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive mcp`
- **Options:** `--json`, `--context`
- **Output:** Usage error text on stderr naming `import` and `login` (or JSON error envelope when `--json` is passed).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND` (`import` or `login`).
- **Effects and approvals:** No side effects.
- **Example:** `hive mcp import --dry-run --json`

### `hive mcp import`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive mcp import`
- **Options:** `--all`, `--only`, `--dry-run`, `--yes`, `--update`, `--json`, `--context`
- **Output:** Interactive selection table or plan text, or single-document JSON (`hive-mcp-import.v1`, [schemas/hive-mcp-import.v1.json](../schemas/hive-mcp-import.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` imported or planned (`--dry-run`), `64` unexpected `SERVER` argument, invalid flags, or non-TTY write without `--all`/`--only` plus `--yes`, `78` malformed global config.
- **Effects and approvals:** Reads personal MCP server definitions from Codex, Claude, OpenCode, Pi, and Grok (converting literal credentials into env-var names) and writes selected entries to `mcp.servers` in `~/.config/hive/config.yml`; `--dry-run` makes no writes, and non-TTY writes require `--all` or `--only` plus `--yes`.
- **Example:** `hive mcp import --dry-run --json`

### `hive mcp login`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive mcp login SERVER --agent AGENT`
- **Options:** `--agent`, `--json`, `--context`
- **Output:** Interactive agent sign-in output on TTY; explicitly rejects `--json` (exit `64`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` sign-in succeeded, `1` sign-in failed, `64` missing `SERVER`, invalid `--agent` (supports `codex` and `claude`), `--json` passed, or import-only flags passed, `78` malformed global config.
- **Effects and approvals:** Runs the interactive OAuth/sign-in flow for catalog server `SERVER` under the specified agent's Hive launch credentials.
- **Example:** `hive mcp login linear --agent codex`

### `hive metrics`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive metrics`
- **Options:** `--days`, `--project`, `--json`, `--context`
- **Output:** Defaults to `metrics rollback-rate`: text table, or single-document JSON (`hive-metrics-rollback-rate.v1`, [schemas/hive-metrics-rollback-rate.v1.json](../schemas/hive-metrics-rollback-rate.v1.json)) on success and error. Error envelopes intentionally omit `error_class`; if `JSON::GeneratorError` occurs while emitting the error envelope, `metrics` suppresses that serialization failure (`:suppress`) and preserves the original typed command error and exit code.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` report generated, `64` unknown subcommand, invalid `--days`, or unknown `--project`, `70` git failure.
- **Effects and approvals:** Read-only `git log` inspection across registered projects.
- **Example:** `hive metrics --days 30 --json`

### `hive metrics rollback-rate`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive metrics rollback-rate`
- **Options:** `--days`, `--project`, `--json`, `--context`
- **Output:** Text table of fix-agent commit rollback ratios, or single-document JSON (`hive-metrics-rollback-rate.v1`, [schemas/hive-metrics-rollback-rate.v1.json](../schemas/hive-metrics-rollback-rate.v1.json)) on success and error. Error envelopes intentionally omit `error_class`; if `JSON::GeneratorError` occurs while encoding an error envelope, `metrics` suppresses that serialization failure (`:suppress`) so the caller still receives the original typed command error and exit code.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` report generated, `64` invalid `--days` (must be a positive integer) or unknown `--project`, `70` git failure.
- **Effects and approvals:** Read-only `git log --since="N days ago"` inspection of fix-agent trailers (`Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Fix-Phase`).
- **Example:** `hive metrics rollback-rate --days 30 --project demo --json`

### `hive module`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module`
- **Options:** `--json`, `--context`
- **Output:** Usage error on stderr listing module subcommands (`install`, `update`, `enable`, `disable`, `uninstall`, `list`, `inspect`, `status`, `doctor`, `dry-run`), or JSON error envelope when `--json` is passed.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND`.
- **Effects and approvals:** No side effects.
- **Example:** `hive module list --json`

### `hive module disable`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module disable NAME`
- **Options:** `--dry-run`, `--yes`, `--receipt`, `--json`, `--context`
- **Output:** Text preview/result, or single-document JSON (`hive-module-lifecycle.v1`, [schemas/hive-module-lifecycle.v1.json](../schemas/hive-module-lifecycle.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` preview built or module disabled, `64` unknown module, missing/stale `--receipt`, or missing `--yes` in non-TTY apply, `70` storage error, `75` lock contention.
- **Effects and approvals:** Preview-bound mutation: run `--dry-run` first, then repeat with `--yes` and the exact `--receipt` to fence new trigger admission while keeping the module installed.
- **Example:** `hive module disable notifier --dry-run --json`

### `hive module doctor`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module doctor NAME`
- **Options:** `--json`, `--context`
- **Output:** Diagnostic text report, or single-document JSON (`hive-module-doctor.v1`, [schemas/hive-module-doctor.v1.json](../schemas/hive-module-doctor.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` healthy, `1` actionable diagnostic findings, `64` unknown `NAME`, `78` malformed module config.
- **Effects and approvals:** Read-only diagnosis; never repairs module state.
- **Example:** `hive module doctor notifier --json`

### `hive module dry-run`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module dry-run NAME`
- **Options:** `--event`, `--schedule`, `--occurred-at`, `--json`, `--context`
- **Output:** Evaluated decision report in text, or single-document JSON (`hive-module-dry-run.v1`, [schemas/hive-module-dry-run.v1.json](../schemas/hive-module-dry-run.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` event evaluated, `64` unknown module, invalid `--event`, missing `--schedule` for schedule events, or bad `--occurred-at`, `70` evaluation failure.
- **Effects and approvals:** Read-only simulation of a supplied event or cron schedule against module hooks without writes or triggers.
- **Example:** `hive module dry-run notifier --event schedule --schedule "0 9 * * *" --json`

### `hive module enable`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module enable NAME`
- **Options:** `--dry-run`, `--yes`, `--receipt`, `--json`, `--context`
- **Output:** Text preview/result, or single-document JSON (`hive-module-lifecycle.v1`, [schemas/hive-module-lifecycle.v1.json](../schemas/hive-module-lifecycle.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` preview built or module enabled, `64` unknown module, missing/stale `--receipt`, or missing `--yes`, `70` storage error, `75` lock contention.
- **Effects and approvals:** Preview-bound mutation (`--dry-run`, then `--yes --receipt <id>`) resuming future trigger admission for `NAME`.
- **Example:** `hive module enable notifier --dry-run --json`

### `hive module inspect`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module inspect NAME`
- **Options:** `--json`, `--context`
- **Output:** Text inspection of installed or retained module metadata/history, or single-document JSON (`hive-module-status.v1`, [schemas/hive-module-status.v1.json](../schemas/hive-module-status.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` inspected, `64` unknown module `NAME`, `70` read error.
- **Effects and approvals:** Read-only.
- **Example:** `hive module inspect notifier --json`

### `hive module install`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module install honeycomb/NAME[@VERSION]`
- **Options:** `--dry-run`, `--yes`, `--receipt`, `--grant`, `--hook`, `--setting`, `--mapping`, `--input-binding`, `--allow-escalation`, `--json`, `--context`
- **Output:** Text preview/result, or single-document JSON (`hive-module-lifecycle.v1`, [schemas/hive-module-lifecycle.v1.json](../schemas/hive-module-lifecycle.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed or installed, `64` invalid package reference, missing required `--setting`/`--hook`/`--grant`/`--receipt`/`--yes` in non-TTY mode, or unapproved escalation without `--allow-escalation`, `69` registry unreachable, `70` verification/install failure.
- **Effects and approvals:** Preview-bound mutation: run `--dry-run` first to review hooks, settings, bindings, and grants (`CATEGORY=VALUE`; `repository_write` is boolean), then re-run with `--yes --receipt <id>`.
- **Example:** `hive module install honeycomb/notifier --dry-run --json`

### `hive module list`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module list`
- **Options:** `--json`, `--context`
- **Output:** Text table of installed project modules, or single-document JSON (`hive-module-list.v1`, [schemas/hive-module-list.v1.json](../schemas/hive-module-list.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed, `64` invalid arguments, `78` malformed project config.
- **Effects and approvals:** Read-only.
- **Example:** `hive module list --json`

### `hive module status`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module status [NAME]`
- **Options:** `--json`, `--context`
- **Output:** Shared redacted module status text, or single-document JSON (`hive-module-status.v1`, [schemas/hive-module-status.v1.json](../schemas/hive-module-status.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` status reported, `64` unknown `NAME`, `70` read error.
- **Effects and approvals:** Read-only.
- **Example:** `hive module status --json`

### `hive module uninstall`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module uninstall NAME`
- **Options:** `--dry-run`, `--yes`, `--receipt`, `--json`, `--context`
- **Output:** Text preview/result, or single-document JSON (`hive-module-lifecycle.v1`, [schemas/hive-module-lifecycle.v1.json](../schemas/hive-module-lifecycle.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed or uninstalled, `64` unknown `NAME`, missing/stale `--receipt`, or missing `--yes`, `70` storage error, `75` lock contention.
- **Effects and approvals:** Preview-bound mutation (`--dry-run`, then `--yes --receipt <id>`) that stops dispatch for `NAME` while retaining audit history.
- **Example:** `hive module uninstall notifier --dry-run --json`

### `hive module update`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive module update NAME`
- **Options:** `--dry-run`, `--yes`, `--receipt`, `--grant`, `--hook`, `--setting`, `--mapping`, `--input-binding`, `--allow-escalation`, `--json`, `--context`
- **Output:** Text diff/result, or single-document JSON (`hive-module-lifecycle.v1`, [schemas/hive-module-lifecycle.v1.json](../schemas/hive-module-lifecycle.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed or updated, `64` unknown `NAME`, missing/stale `--receipt`/`--yes`, or unapproved escalation without `--allow-escalation`, `69` registry unreachable, `70` update failure.
- **Effects and approvals:** Preview-bound mutation (`--dry-run`, then `--yes --receipt <id>`) advancing a reviewed module package; capability escalations additionally require `--allow-escalation`.
- **Example:** `hive module update notifier --dry-run --json`

### `hive new`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive new PROJECT TEXT`
- **Options:** `--base`, `--depends-on`, `--workflow`, `--idempotency-key`, `--json`, `--context`
- **Output:** Text task summary, or single-document JSON: locally emits `hive-new.v1` ([schemas/hive-new.v1.json](../schemas/hive-new.v1.json)) on success and error (`:raise` serialization policy); remotely emits `hive-remote.v1` ([schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json)).
- **Context behavior:** Local creates the task directly in `PROJECT`'s entry stage (lifting known flags placed between `PROJECT` and `TEXT` while preserving prose after `--`). Remote validates `PROJECT`, non-blank `TEXT`, `--base`, repeatable `--depends-on`, `--workflow`, and `--idempotency-key`, then POSTs `/projects/<project>/tasks`.
- **Exits and retry:** `0` created or replayed by `--idempotency-key`, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` unknown project, blank text, invalid workflow/dependency, `69`/`75` transient remote or lock failure (replay lost remote response with the reported `idempotency_key` and `target`), `70` storage error, `78` config error.
- **Effects and approvals:** Creates a durable task folder in the workflow's entry stage and commits state; supplying `--idempotency-key` makes retries return the existing task.
- **Example:** `hive new demo --workflow editorial --idempotency-key creator:42 --json "draft a launch post"`

### `hive open-pr`

- **Aliases:** `pr`
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive open-pr TARGET`
- **Options:** `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` invalid target/options, `70` git/GitHub/stage failure, `75` lock contention.
- **Effects and approvals:** Promotes a completed `4-execute` task into `5-open-pr` (if not already there), pushes the task branch, and opens a draft pull request.
- **Example:** `hive open-pr my-task --from 4-execute --json`

### `hive operation`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive operation ID --project PROJECT`
- **Options:** `--project`, `--json`, `--context`
- **Output:** Text operation status and linked task progress, or single-document JSON (`hive-operation.v1`, [schemas/hive-operation.v1.json](../schemas/hive-operation.v1.json)) on success and error.
- **Context behavior:** Requires a remote context (`--context <remote>`); under a local context preflight refuses before runtime activation with exit `64` (`operation lookup requires --context <remote>; use hive receipt for local commands`).
- **Exits and retry:** `0` operation inspected (safe read-only polling), `64` local context selected, missing `--project`, or invalid `ID`, `69` remote server unreachable or unauthorized, `70` remote protocol error.
- **Effects and approvals:** Read-only remote durable-operation lookup.
- **Example:** `hive operation op_123 --project demo --context prod --json`

### `hive pairing`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive pairing`
- **Options:** `--json`, `--context`
- **Output:** Usage error on stderr listing `list` and `approve`, or JSON error envelope when `--json` is passed.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND`.
- **Effects and approvals:** No side effects.
- **Example:** `hive pairing list --json`

### `hive pairing approve`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive pairing approve telegram <CODE> [--json]`
- **Options:** `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-pairing-approve.v1`, [schemas/hive-pairing-approve.v1.json](../schemas/hive-pairing-approve.v1.json)); on non-usage failures inspect `error_kind` (`unknown_code`, `expired_code`, `notice_write_failed`, `store_read_failed`, `internal_error`) rather than exit code alone.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` pairing approved, `1` unknown/expired code, notice write failure, unreadable store, or internal error, `64` invalid platform (must be literal `telegram`) or missing `<CODE>`, `78` malformed global bot config.
- **Effects and approvals:** Appends the Telegram `chat_id` to `bot.chat_id_allowlist` in global config, signals a live bot reload if running, and queues an approval DM.
- **Example:** `hive pairing approve telegram ABCD1234 --json`

### `hive pairing list`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive pairing list [--json]`
- **Options:** `--json`, `--context`
- **Output:** Text list of pending Telegram pairing requests, or single-document JSON (`hive-pairing-list.v1`, [schemas/hive-pairing-list.v1.json](../schemas/hive-pairing-list.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed, `1` store read failure, `64` invalid arguments, `78` bad global bot config.
- **Effects and approvals:** Read-only.
- **Example:** `hive pairing list --json`

### `hive patrol`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive patrol PROJECT`
- **Modes:**
  - **Mode `cycle`** (condition: `without --list and without --once`; options: `--dry-run`, `--json`, `--context`): Runs one repository defect patrol cycle against an exact detached default-branch snapshot for `PROJECT` (`hive-patrol.v3`).
  - **Mode `list`** (condition: `--list`; options: `--list`, `--json`, `--context`): Read-only listing of recorded patrol findings (`hive-patrol-findings.v1`).
  - **Mode `once`** (condition: `--once`; options: `--once`, `--dry-run`, `--json`, `--context`): Runs one bounded external-scheduler patrol pass and emits `hive-one-shot.v1`.
- **Options:** `--dry-run`, `--list`, `--once`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON per mode: `cycle` emits `hive-patrol.v3` ([schemas/hive-patrol.v3.json](../schemas/hive-patrol.v3.json)), `list` emits `hive-patrol-findings.v1` ([schemas/hive-patrol-findings.v1.json](../schemas/hive-patrol-findings.v1.json)), and `once` always emits `hive-one-shot.v1` ([schemas/hive-one-shot.v1.json](../schemas/hive-one-shot.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` cycle/list/one-shot completed, `64` unknown project or incompatible flags, `70` review/fix/git failure, `75` live owner or lock contention (retryable), `78` malformed patrol config.
- **Effects and approvals:** `list` and `--dry-run` are read-only; live `cycle` and `once` update `.hive-state/patrol/` state, run regression-verified fixes for qualifying findings, open PRs, and optionally hand off to `6-review`.
- **Example:** `hive patrol my-project --dry-run --json`

### `hive plan`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan TARGET`
- **Options:** `--from`, `--project`, `--review-level`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` invalid target or `--review-level`, `70` stage/agent failure, `75` lock contention.
- **Effects and approvals:** Promotes a completed `2-brainstorm` task into `3-plan` (if not already there) and runs the planning stage agent (optionally overriding plan-review strictness via `--review-level`).
- **Example:** `hive plan my-task --from 2-brainstorm --json`

### `hive plan-review TARGET answer-finding`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET answer-finding`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--answer`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` answer recorded, `4` stale/conflicting freshness identity (re-read `hive plan-review TARGET show --json` and retry), `64` missing required freshness flags or `--answer`, `70` storage error, `75` lock contention.
- **Effects and approvals:** Records an operator answer on the targeted plan-review finding under freshness CAS (`--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`).
- **Example:** `hive plan-review my-task answer-finding --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --target-fingerprint f1 --answer "Confirmed" --json`

### `hive plan-review TARGET approve-finding`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET approve-finding`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` finding approved, `4` stale/conflicting freshness identity, `64` missing required freshness flags, `70` storage error, `75` lock contention.
- **Effects and approvals:** Approves the targeted plan-review finding under freshness CAS and returns the next observation digest.
- **Example:** `hive plan-review my-task approve-finding --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --target-fingerprint f1 --json`

### `hive plan-review TARGET downgrade-level`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET downgrade-level`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--level`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` level downgraded, `4` stale/conflicting freshness identity, `64` missing freshness flags, invalid `--level`, or missing `--reason`, `70` storage error, `75` lock contention.
- **Effects and approvals:** Downgrades the active plan critique level with an audit reason under freshness CAS.
- **Example:** `hive plan-review my-task downgrade-level --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --level standard --reason "Low risk" --json`

### `hive plan-review TARGET raise-level`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET raise-level`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--level`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` level raised, `4` stale/conflicting freshness identity, `64` missing freshness flags or invalid `--level`, `70` storage error, `75` lock contention.
- **Effects and approvals:** Raises the active plan critique level under freshness CAS.
- **Example:** `hive plan-review my-task raise-level --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --level strict --json`

### `hive plan-review TARGET request-review`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET request-review`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` review requested, `4` stale/conflicting freshness identity, `64` missing freshness flags, `70` storage error, `75` lock contention.
- **Effects and approvals:** Requests a new plan critique pass for `TARGET` under freshness CAS.
- **Example:** `hive plan-review my-task request-review --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --json`

### `hive plan-review TARGET restart`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET restart`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` linked review started for current generation, `4` review is not stale or freshness identity mismatched, `64` missing freshness flags, `70` storage error, `75` lock contention.
- **Effects and approvals:** Applies only to a stale review (task generation, plan, or policy changed) and starts a linked review for the current generation.
- **Example:** `hive plan-review my-task restart --review-id rev1 --task-generation g2 --policy-fingerprint p2 --expected-artifact-digest a2 --json`

### `hive plan-review TARGET retry`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET retry`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` critique retry admitted, `4` stale/conflicting freshness identity, `64` missing freshness flags, `70` storage error, `75` lock contention.
- **Effects and approvals:** Retries a failed or blocked plan critique generation under freshness CAS.
- **Example:** `hive plan-review my-task retry --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --json`

### `hive plan-review TARGET show`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET show`
- **Options:** `--project`, `--json`, `--context`
- **Output:** Live task plan-review summary in text, or single-document JSON (`hive-plan-review-show.v1`, [schemas/hive-plan-review-show.v1.json](../schemas/hive-plan-review-show.v1.json)) exposing authoritative live `review_id`, `task_generation`, `policy_fingerprint`, `artifact_digest`, and `target_fingerprint` identities (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` shown, `64` unknown task or mutation-only flags supplied, `70` storage/read error.
- **Effects and approvals:** Strictly read-only live inspection (never relies on daemon-cached status snapshots).
- **Example:** `hive plan-review my-task show --json`

### `hive plan-review TARGET waive-coverage`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review TARGET waive-coverage`
- **Options:** `--project`, `--review-id`, `--task-generation`, `--policy-fingerprint`, `--expected-artifact-digest`, `--target-fingerprint`, `--coverage`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation with next observation digest, or single-document JSON (`hive-plan-review-action.v1`, [schemas/hive-plan-review-action.v1.json](../schemas/hive-plan-review-action.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` coverage waived, `4` stale/conflicting freshness identity, `64` missing freshness flags, `--coverage`, or `--reason`, `70` storage error, `75` lock contention.
- **Effects and approvals:** Records an audited waiver for missing critique lens coverage under freshness CAS.
- **Example:** `hive plan-review my-task waive-coverage --review-id rev1 --task-generation g1 --policy-fingerprint p1 --expected-artifact-digest a1 --coverage security --reason "Docs only" --json`

### `hive plan-review-run`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive plan-review-run TARGET`
- **Options:** `--project`, `--json`, `--context`
- **Output:** Human-readable worker execution log; `--json` is ignored (text-only).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` critique worker completed, `64` unknown task, `70` reviewer execution failure, `75` lock contention.
- **Effects and approvals:** Starts or resumes plan critique execution for `TARGET` without operator decision authority.
- **Example:** `hive plan-review-run my-task --project demo`

### `hive proposal`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal`
- **Options:** `--json`, `--context`
- **Output:** Usage error on stderr listing proposal subcommands (`submit`, `evaluate`, `list`, `show`, `filter`, `decide`, `supersede`, `rollback`, `refresh`), or JSON error envelope when `--json` is passed.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND`.
- **Effects and approvals:** No side effects.
- **Example:** `hive proposal list --json`

### `hive proposal decide`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal decide PROPOSAL_ID --input FILE --authority ID --policy-fingerprint SHA --expected-head-version N --expected-head-digest SHA`
- **Options:** `--input`, `--authority`, `--policy-fingerprint`, `--expected-head-version`, `--expected-head-digest`, `--considered-evaluations`, `--project`, `--json`, `--context`
- **Output:** Text decision summary, or single-document JSON (`hive-proposal-mutation.v1`, [schemas/hive-proposal-mutation.v1.json](../schemas/hive-proposal-mutation.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` lifecycle decision recorded, `64` missing/invalid CAS head flags or input JSON, `70` storage/git failure, `75` head conflict or lock contention, `78` authority policy config error.
- **Effects and approvals:** Tracking-only lifecycle mutation against canonical `hive/state` proposal records requiring a fresh observed head version and digest.
- **Example:** `hive proposal decide prop-1 --input decision.json --authority ops --policy-fingerprint <sha> --expected-head-version 1 --expected-head-digest <sha> --json`

### `hive proposal evaluate`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal evaluate TASK --input FILE --proposal-id ID --evaluator ID`
- **Options:** `--input`, `--proposal-id`, `--evaluator`, `--method`, `--project`, `--json`, `--context`
- **Output:** Text evaluation receipt, or single-document JSON (`hive-proposal-mutation.v1`, [schemas/hive-proposal-mutation.v1.json](../schemas/hive-proposal-mutation.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` evaluation appended, `64` invalid `--input` or missing required options, `70` storage failure, `75` lock contention.
- **Effects and approvals:** Uses or creates a durable proposal-bound task attempt and appends an immutable evaluation event for `--proposal-id`.
- **Example:** `hive proposal evaluate my-task --input eval.json --proposal-id prop-1 --evaluator ci --json`

### `hive proposal filter`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal filter [PROJECT_PATH] [--kind KIND] [--status STATUS]`
- **Options:** `--kind`, `--status`, `--subject`, `--revision`, `--evaluator`, `--method`, `--relation`, `--include-drafts`, `--include-quarantine`, `--json`, `--context`
- **Output:** Filtered text table, or single-document JSON (`hive-proposal-list.v1`, [schemas/hive-proposal-list.v1.json](../schemas/hive-proposal-list.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` filtered, `64` invalid filter criteria, `70` projection read failure.
- **Effects and approvals:** Read-only query over canonical `hive/state` proposal projections.
- **Example:** `hive proposal filter --kind skill --status accepted --json`

### `hive proposal list`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal list [PROJECT_PATH]`
- **Options:** `--include-drafts`, `--include-quarantine`, `--json`, `--context`
- **Output:** Text proposal index, or single-document JSON (`hive-proposal-list.v1`, [schemas/hive-proposal-list.v1.json](../schemas/hive-proposal-list.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed, `64` invalid project path, `70` projection read failure.
- **Effects and approvals:** Read-only query over canonical `hive/state` proposal projections.
- **Example:** `hive proposal list --include-drafts --json`

### `hive proposal refresh`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal refresh [PROJECT_PATH]`
  - `hive proposal refresh [PROJECT_PATH] --check`
- **Modes:**
  - **Mode `queue`** (condition: `without --check`; options: `--json`, `--context`): Rebuilds/publishes generated proposal Wiki views through the managed `llm-wiki` boundary.
  - **Mode `check`** (condition: `--check`; options: `--check`, `--json`, `--context`): Read-only freshness verification of generated proposal views without publishing.
- **Options:** `--check`, `--json`, `--context`
- **Output:** Text status, or single-document JSON (`hive-proposal-mutation.v1`, [schemas/hive-proposal-mutation.v1.json](../schemas/hive-proposal-mutation.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` views fresh or refreshed, `1` `--check` detected drifted generated views, `64` invalid project path, `70` compiler/git failure.
- **Effects and approvals:** `check` is read-only; `queue` compiles and updates generated proposal views inside the managed refresh boundary.
- **Example:** `hive proposal refresh --check --json`

### `hive proposal rollback`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal rollback PROPOSAL_ID --input FILE --authority ID --policy-fingerprint SHA --expected-head-version N --expected-head-digest SHA`
- **Options:** `--input`, `--authority`, `--policy-fingerprint`, `--expected-head-version`, `--expected-head-digest`, `--considered-evaluations`, `--project`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-proposal-mutation.v1`, [schemas/hive-proposal-mutation.v1.json](../schemas/hive-proposal-mutation.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` rollback recorded, `64` missing/invalid flags or input JSON, `70` storage failure, `75` head conflict or lock contention, `78` authority config error.
- **Effects and approvals:** Tracking-only lifecycle rollback requiring a fresh observed head version and digest.
- **Example:** `hive proposal rollback prop-1 --input rollback.json --authority ops --policy-fingerprint <sha> --expected-head-version 2 --expected-head-digest <sha> --json`

### `hive proposal show`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal show PROPOSAL_ID`
- **Options:** `--include-drafts`, `--include-quarantine`, `--project`, `--json`, `--context`
- **Output:** Text proposal detail with head version/digest, or single-document JSON (`hive-proposal-show.v1`, [schemas/hive-proposal-show.v1.json](../schemas/hive-proposal-show.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` shown, `64` unknown `PROPOSAL_ID`, `70` read error.
- **Effects and approvals:** Read-only.
- **Example:** `hive proposal show prop-1 --json`

### `hive proposal submit`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal submit TASK --input FILE --kind KIND --subject REF --revision REV`
- **Options:** `--input`, `--kind`, `--subject`, `--revision`, `--project`, `--json`, `--context`
- **Output:** Text submission receipt, or single-document JSON (`hive-proposal-mutation.v1`, [schemas/hive-proposal-mutation.v1.json](../schemas/hive-proposal-mutation.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` proposal submitted, `64` missing/invalid input JSON or required flags, `70` storage failure, `75` lock contention.
- **Effects and approvals:** Uses or creates a durable proposal-bound task attempt and persists the submitted skill or workflow proposal.
- **Example:** `hive proposal submit my-task --input prop.json --kind skill --subject hive --revision r1 --json`

### `hive proposal supersede`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive proposal supersede PROPOSAL_ID --input FILE --authority ID --policy-fingerprint SHA --expected-head-version N --expected-head-digest SHA`
- **Options:** `--input`, `--authority`, `--policy-fingerprint`, `--expected-head-version`, `--expected-head-digest`, `--considered-evaluations`, `--project`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-proposal-mutation.v1`, [schemas/hive-proposal-mutation.v1.json](../schemas/hive-proposal-mutation.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` supersession recorded, `64` missing/invalid CAS flags or input JSON, `70` storage failure, `75` head conflict or lock contention, `78` authority config error.
- **Effects and approvals:** Tracking-only lifecycle supersession requiring a fresh observed head version and digest.
- **Example:** `hive proposal supersede prop-1 --input supersede.json --authority ops --policy-fingerprint <sha> --expected-head-version 2 --expected-head-digest <sha> --json`

### `hive prune`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive prune`
- **Options:** `--dry-run`, `--json`, `--context`
- **Output:** Text summary of stale registry rows, or single-document JSON (`hive-prune.v1`, [schemas/hive-prune.v1.json](../schemas/hive-prune.v1.json)) on success and error (`:warn` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` pruned or dry-run reported (idempotent), `70` write failure, `78` malformed global registry config.
- **Effects and approvals:** Removes stale, retargeted, or malformed project entries from the global registry unless `--dry-run` is set.
- **Example:** `hive prune --dry-run --json`

### `hive publication-reconcile`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive publication-reconcile TARGET --head HEAD --pr PR`
- **Options:** `--head`, `--pr`, `--project`, `--json`, `--context`
- **Output:** Text summary, or success-only schema-less JSON (`--json` emits the reconciled publication object on success; failures report errors on stderr without a JSON error envelope).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` publication record reconciled, `64` task has no coding publication record or invalid `--head`/`--pr`, `70` git/storage error, `75` task lock contention.
- **Effects and approvals:** Adopts an inspected PR revision into the local coding publication record without pushing to GitHub.
- **Example:** `hive publication-reconcile my-task --head abc1234 --pr 42 --json`

### `hive rebase-status`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive rebase-status TARGET`
- **Options:** `--project`, `--stage`, `--json`, `--context`
- **Output:** Text report of whether the next run would auto-rebase, or single-document JSON (`hive-rebase-status` v1, on success and usage error).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` status reported, `64` unknown/ambiguous `TARGET`, `70` git inspection error.
- **Effects and approvals:** Strictly read-only git/worktree inspection.
- **Example:** `hive rebase-status my-task --json`

### `hive receipt abandon-batch`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive receipt abandon-batch IDENTIFIER`
- **Options:** `--project`, `--namespace-id`, `--expected-generation`, `--confirm`, `--reason`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-command-receipt.v1`, [schemas/hive-command-receipt.v1.json](../schemas/hive-command-receipt.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` batch abandoned, `20` conflict / generation mismatch, `21` still in progress, `22` unresolved outcome, `64` missing `IDENTIFIER`, `--expected-generation`, `--confirm`, or `--reason`, `75` transient storage contention, `78` config error.
- **Effects and approvals:** Destructive receipt-batch abandonment guarded by `--expected-generation`, `--confirm`, and `--reason`.
- **Example:** `hive receipt abandon-batch batch-1 --project demo --expected-generation 2 --confirm --reason "operator cleanup" --json`

### `hive receipt enroll`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive receipt enroll`
- **Options:** `--project`, `--new-identity`, `--previous-identity`, `--expected-generation`, `--confirm`, `--reason`, `--json`, `--context`
- **Output:** Text enrollment receipt, or single-document JSON (`hive-command-receipt.v1`, [schemas/hive-command-receipt.v1.json](../schemas/hive-command-receipt.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` enrolled, `20` generation/identity conflict, `64` missing `--project`, `--confirm`, or required identity replacement flags, `75` transient contention, `78` config failure.
- **Effects and approvals:** Enrolls a project namespace in durable command receipts (or mints a replacement identity with `--new-identity --previous-identity UUID --expected-generation N --confirm`).
- **Example:** `hive receipt enroll --project demo --new-identity --previous-identity 00000000-0000-4000-8000-000000000001 --expected-generation 4 --confirm --json`

### `hive receipt prune`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive receipt prune`
- **Modes:**
  - **Mode `preview`** (condition: `without --confirm`; options: `--project`, `--namespace-id`, `--limit`, `--cursor`, `--json`, `--context`): Read-only paginated preview of prunable durable command receipts (default `--limit 100`, max `1000`, with stable `--cursor`).
  - **Mode `confirm`** (condition: `--confirm`; options: `--project`, `--namespace-id`, `--limit`, `--confirm`, `--reason`, `--idempotency-key`, `--json`, `--context`): Commits bounded pruning of eligible terminal receipts with an audit `--reason` and optional `--idempotency-key`.
- **Options:** `--project`, `--namespace-id`, `--limit`, `--cursor`, `--confirm`, `--reason`, `--idempotency-key`, `--json`, `--context`
- **Output:** Text summary, or single-document JSON (`hive-receipt-prune.v1`, [schemas/hive-receipt-prune.v1.json](../schemas/hive-receipt-prune.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed or pruned, `20`/`21`/`22` receipt conflict/in-progress/unresolved, `64` invalid flags or missing `--reason` with `--confirm`, `75` transient prune contention or storage pressure (retryable), `78` config failure.
- **Effects and approvals:** `preview` is read-only; `confirm` deletes eligible expired receipts under `--confirm` and `--reason`.
- **Example:** `hive receipt prune --project demo --json`

### `hive receipt release-pin`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive receipt release-pin IDENTIFIER`
- **Options:** `--project`, `--namespace-id`, `--expected-generation`, `--force`, `--confirm`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-command-receipt.v1`, [schemas/hive-command-receipt.v1.json](../schemas/hive-command-receipt.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` pin released, `20` generation conflict, `21` work still in progress, `22` unresolved outcome, `64` missing `IDENTIFIER`, `--expected-generation`, `--force`, `--confirm`, or `--reason`, `75` transient contention, `78` config failure.
- **Effects and approvals:** Explicitly releases a pinned command receipt after caller intent closes; requires `--expected-generation`, `--force`, `--confirm`, and `--reason`.
- **Example:** `hive receipt release-pin pin-1 --expected-generation 1 --force --confirm --reason "caller intent closed" --json`

### `hive receipt retire`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `inline_help_and_dispatcher`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive receipt retire IDENTIFIER`
- **Modes:**
  - **Mode `settle_without_result`** (condition: `--settle-without-result`; options: `--project`, `--namespace-id`, `--expected-generation`, `--confirm`, `--settle-without-result`, `--reason`, `--json`, `--context`): Terminalizes an unresolved receipt without claiming its original result.
  - **Mode `orphaned_owner`** (condition: `--orphaned-owner`; options: `--project`, `--namespace-id`, `--expected-generation`, `--confirm`, `--orphaned-owner`, `--reason`, `--json`, `--context`): Reclassifies an executing receipt whose recorded owner process is proven dead.
  - **Mode `with_evidence`** (condition: `--evidence FILE`; options: `--project`, `--namespace-id`, `--expected-generation`, `--confirm`, `--evidence`, `--reason`, `--json`, `--context`): Retires a receipt using bounded JSON outcome evidence supplied via `--evidence FILE`.
- **Options:** `--project`, `--namespace-id`, `--expected-generation`, `--confirm`, `--settle-without-result`, `--orphaned-owner`, `--evidence`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-command-receipt.v1`, [schemas/hive-command-receipt.v1.json](../schemas/hive-command-receipt.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` retired/reclassified, `20` generation conflict, `21` owner still live / in progress, `22` unresolved outcome mismatch, `64` missing `IDENTIFIER`, `--expected-generation`, `--confirm`, `--reason`, or mutually exclusive mode flag, `75` transient contention, `78` config failure.
- **Effects and approvals:** Mutates durable command-receipt state under `--expected-generation`, `--confirm`, `--reason`, and exactly one retirement mode (`--settle-without-result`, `--orphaned-owner`, or `--evidence FILE`).
- **Example:** `hive receipt retire rcpt-1 --expected-generation 3 --settle-without-result --confirm --reason "operator reconciliation" --json`

### `hive refactor-patrol`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive refactor-patrol PROJECT`
- **Modes:**
  - **Mode `discover`** (condition: `without --list, --show, --archive, --once`; options: `--dry-run`, `--feature`, `--entrypoint`, `--path`, `--changed-since`, `--pr`, `--job-manifest`, `--result-file`, `--json`, `--context`): Runs architecture-patrol discovery/execution for `PROJECT` (`--changed-since REF` pairs only with `--feature`, `--entrypoint`, or `--path`; emits `hive-refactor-patrol.v4`).
  - **Mode `list`** (condition: `--list`; options: `--list`, `--limit`, `--cursor`, `--json`, `--context`): Non-mutating paginated listing of durable architecture-patrol jobs emitting `hive-refactor-patrol-jobs.v2`; pages default to 100 records and the opaque continuation cursor freezes the intake-sequence high-water mark so later arrivals cannot alter page membership.
  - **Mode `show`** (condition: `--show JOB_ID`; options: `--show`, `--limit`, `--full`, `--json`, `--context`): Non-mutating inspection of one job emitting `hive-refactor-patrol-jobs.v2`; defaults to the latest 100 discovery attempts, action claims, and publication attempts per history (`--limit 1..100` narrows it, `--full` opts into complete unbounded histories including all legacy flat patches).
  - **Mode `archive`** (condition: `--archive JOB_ID`; options: `--archive`, `--json`, `--context`): Archives one durable architecture-patrol job (`hive-refactor-patrol-jobs.v2`).
  - **Mode `once`** (condition: `--once`; options: `--once`, `--dry-run`, `--json`, `--context`): Runs one bounded external-scheduler architecture-patrol pass and emits `hive-one-shot.v1`.
- **Options:** `--dry-run`, `--feature`, `--entrypoint`, `--path`, `--changed-since`, `--pr`, `--job-manifest`, `--result-file`, `--list`, `--show`, `--archive`, `--limit`, `--cursor`, `--full`, `--once`, `--json`, `--context`
- **Output:** Text report, or single-document JSON per mode: `discover` emits `hive-refactor-patrol.v4` ([schemas/hive-refactor-patrol.v4.json](../schemas/hive-refactor-patrol.v4.json)), `list`/`show`/`archive` emit `hive-refactor-patrol-jobs.v2` ([schemas/hive-refactor-patrol-jobs.v2.json](../schemas/hive-refactor-patrol-jobs.v2.json)), and `once` always emits `hive-one-shot.v1` ([schemas/hive-one-shot.v1.json](../schemas/hive-one-shot.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` succeeded, `64` unknown project/job, invalid `--limit`/`--cursor`, or conflicting mode flags, `70` discovery/action failure, `75` live owner/claim contention (retryable; incomplete discovery uses 60s retry, token/turn limit uses 1h cooldown), `78` config error.
- **Effects and approvals:** `list`, `show`, and `--dry-run` are read-only; `archive` marks the job archived; `discover` and `once` claim/run architecture-patrol theses and confined auto-fix/PR or issue fallback when enabled.
- **Example:** `hive refactor-patrol my-project --list --limit 50 --json`

### `hive reject-finding`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive reject-finding TARGET [ID...]`
- **Options:** `--project`, `--stage`, `--pass`, `--severity`, `--all`, `--json`, `--context`
- **Output:** Text summary of toggled review findings, or single-document JSON (`hive-findings.v1`, [schemas/hive-findings.v1.json](../schemas/hive-findings.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` toggled (idempotent for already-rejected IDs), `64` invalid target/selector/options, `70` file/internal error, `75` task lock contention.
- **Effects and approvals:** Unticks selected GFM checkboxes to `[ ]` in `reviews/ce-review-NN.md` under the task lock.
- **Example:** `hive reject-finding my-task --severity nit --json`

### `hive review`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive review [TARGET]`
- **Modes:**
  - **Mode `task`** (condition: `TARGET without --pr`; options: `--from`, `--project`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`): Promotes a completed `5-open-pr` task into `6-review` (if not already there) and runs the autonomous review loop (`hive-stage-action.v2`, `:raise`).
  - **Mode `adhoc_pr`** (condition: `--pr PR without TARGET`; options: `--pr`, `--project`, `--json`, `--context`): Creates or reuses a synthetic `6-review/adhoc-review-pr-<N>/` task for an existing GitHub PR (`197`, `#197`, or `/pull/197` URL) in the current registered repo (or `--project`), fetches the PR head into a worktree, and runs the review stage (`:warn` serialization policy).
  - **Mode `missing_target`** (condition: `no TARGET and no --pr`; options: `--json`, `--context`): Fails with usage error (`64`) because either `TARGET` or `--pr PR` is required.
- **Options:** `--from`, `--project`, `--pr`, `--idempotency-key`, `--retry-horizon-expires-at`, `--json`, `--context`
- **Output:** Text progress, or single-document JSON (`hive-stage-action.v2`, [schemas/hive-stage-action.v2.json](../schemas/hive-stage-action.v2.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` completed, `3` task in error, `4` wrong stage, `20`/`21`/`22` durable receipt conflict/in-progress/unresolved, `64` missing both `TARGET` and `--pr`, conflicting `TARGET` + `--pr`, or PR already owned by another Hive task, `70` stage/git/GitHub failure, `75` lock contention.
- **Effects and approvals:** `task` promotes and runs the review loop; `adhoc_pr` creates/reuses an ad-hoc review worktree and runs the review loop; `missing_target` has no side effects.
- **Example:** `hive review --pr 197 --project demo --json`

### `hive review-grant`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive review-grant TARGET --evidence-token EVIDENCE_TOKEN --passes PASSES --project PROJECT --reason REASON`
- **Options:** `--project`, `--evidence-token`, `--passes`, `--reason`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-review-grant.v1`, [schemas/hive-review-grant.v1.json](../schemas/hive-review-grant.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` extra fix passes granted, `4` task not in `final-fix-unverified` review state or stale `--evidence-token`, `64` missing required flags or `--passes` outside `1..3`, `70` storage failure, `75` task lock contention.
- **Effects and approvals:** Grants 1–3 additional autonomous review fix passes bound to the current `--evidence-token` with a recorded audit `--reason`.
- **Example:** `hive review-grant my-task --project demo --evidence-token tok_abc --passes 1 --reason "Flaky CI fix" --json`

### `hive run`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive run TARGET`
- **Options:** `--project`, `--stage`, `--no-rebase`, `--json`, `--context`
- **Output:** Stage runner output in text, or single-document JSON (`hive-run.v2`, [schemas/hive-run.v2.json](../schemas/hive-run.v2.json)) on success and error; if error-envelope encoding raises `JSON::GeneratorError`, `run` suppresses the serialization error (`:suppress`) and preserves the original typed failure.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` stage completed, `3` task in error marker state, `4` wrong/unrunnable stage, `64` unknown/ambiguous `TARGET`, `70` stage/git/agent failure, `75` task lock contention.
- **Effects and approvals:** Dispatches the configured stage runner for `TARGET`'s current stage (auto-rebasing the worktree first unless `--no-rebase` is set).
- **Example:** `hive run my-task --project demo --no-rebase --json`

### `hive runtime`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive runtime`
- **Options:** `--json`, `--context`
- **Output:** Usage error text on stderr naming `status`, `projects`, `payloads`, and `init`, or single-document JSON (`hive-runtime-maintenance.v1`, [schemas/hive-runtime-maintenance.v1.json](../schemas/hive-runtime-maintenance.v1.json)) with `error_kind: "usage"`.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `ACTION`.
- **Effects and approvals:** No side effects.
- **Example:** `hive runtime status --json`

### `hive runtime init`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive runtime init`
- **Options:** `--json`, `--context`
- **Output:** Text status summary, or single-document JSON (`hive-runtime-maintenance.v1`, [schemas/hive-runtime-maintenance.v1.json](../schemas/hive-runtime-maintenance.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` database created or already valid (idempotent), `64` invalid arguments, `70` SQLite/filesystem error, `78` malformed global registry or incompatible existing database (existing DB is validated, never auto-repaired).
- **Effects and approvals:** Creates the runtime database if missing and records every globally registered project in it without installing services, skills, bundles, or project enrollments.
- **Example:** `hive runtime init --json`

### `hive runtime payloads`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive runtime payloads`
- **Options:** `--json`, `--context`
- **Output:** Text list of runtime payload references (`kind`, `state`, task/attempt ID, relative and resolved absolute paths; missing storage reports phase `"absent"`), or single-document JSON (`hive-runtime-maintenance.v1`, [schemas/hive-runtime-maintenance.v1.json](../schemas/hive-runtime-maintenance.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed (including `"absent"` storage), `64` invalid arguments, `70` read error.
- **Effects and approvals:** Strictly read-only (nothing created, migrated, or repaired).
- **Example:** `hive runtime payloads --json`

### `hive runtime projects`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive runtime projects`
- **Options:** `--json`, `--context`
- **Output:** Text list of globally registered projects (`path`, `real_path`, `hive_state_path`), or single-document JSON (`hive-runtime-maintenance.v1`, [schemas/hive-runtime-maintenance.v1.json](../schemas/hive-runtime-maintenance.v1.json)).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed, `64` invalid arguments, `78` malformed global registry.
- **Effects and approvals:** Strictly read-only.
- **Example:** `hive runtime projects --json`

### `hive runtime status`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive runtime status`
- **Options:** `--json`, `--context`
- **Output:** Text validation summary, or single-document JSON (`hive-runtime-maintenance.v1`, [schemas/hive-runtime-maintenance.v1.json](../schemas/hive-runtime-maintenance.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` current runtime database valid, `1` runtime database absent, `70` storage read error, `78` incompatible schema.
- **Effects and approvals:** Strictly read-only (nothing created, migrated, or repaired).
- **Example:** `hive runtime status --json`

### `hive setup`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive setup`
- **Modes:**
  - **Mode `managed_service`** (condition: `default --service without --no-bootstrap`; options: `--yes`, `--service`, `--no-init`, `--install-command-receipts`, `--json`, `--context`): Provisions native loopback Hive web (`http://127.0.0.1:4567`), installs/enables the managed per-user web and daemon services on supported Linux/macOS (preserving any drifted customized unit and pointing to `hive web install --force`), initializes runtime storage, and optionally enrolls the current project unless `--no-init` is passed.
  - **Mode `service_opt_out`** (condition: `--no-service without --no-bootstrap`; options: `--yes`, `--service`, `--no-init`, `--install-command-receipts`, `--json`, `--context`): Performs runtime/web-bundle/enrollment provisioning while only observing any existing web service without installing, stopping, or disabling one.
  - **Mode `diagnose_only`** (condition: `--no-bootstrap`; options: `--no-bootstrap`, `--service`, `--no-init`, `--yes`, `--install-command-receipts`, `--json`, `--context`): Strictly read-only diagnosis suppressing all provisioning and state writes.
- **Options:** `--yes`, `--service`, `--no-bootstrap`, `--no-init`, `--install-command-receipts`, `--json`, `--context`
- **Output:** Human-readable setup checklist, or single-document JSON (`hive-setup.v1`, [schemas/hive-setup.v1.json](../schemas/hive-setup.v1.json)) keeping `mode`, effective `url`, compatibility `warnings`, and service installed/enabled/running/readiness distinct.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` setup or diagnosis succeeded (idempotent on re-run), `1` incomplete/failed provisioning step, `64` invalid flags or declined non-interactive consent, `70` service/runtime failure, `78` config error.
- **Effects and approvals:** `diagnose_only` is read-only. Default setup writes loopback-only config/runtime/services and never creates LAN/public exposure; `--yes` confirms unattended setup steps.
- **Example:** `hive setup --no-bootstrap --json`

### `hive setup-agents`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive setup-agents`
- **Options:** `--yes`, `--agent`, `--skill`, `--json`, `--context`
- **Output:** Preview table and re-verified outcome text, or single-document JSON (`hive-setup-agents.v1`, [schemas/hive-setup-agents.v1.json](../schemas/hive-setup-agents.v1.json)) reporting per-operation status (`planned`, `skipped`, `succeeded`, `failed`). JSON mode writes only its single document to stdout and never prompts.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` all targeted skills healthy or provisioned (matching installs are no-ops; retries re-inspect and schedule only unresolved work), `1` an attempted operation failed or an actionable residual remains, `64` consent declined or planned mutation requested in `--json`/non-TTY mode without `--yes`, `78` invalid manifest, effective config, or `--agent`/`--skill` filter.
- **Effects and approvals:** Previews exact argv arrays and Hive-owned paths before executing native skill provisioning for configured Claude, Codex, Pi, Grok, OpenCode, Muse, and Agy agents; prompts once on TTY or requires `--yes` unattended.
- **Example:** `hive setup-agents --agent claude --skill ce-brainstorm --yes --json`

### `hive stack`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive stack TARGET --on PREREQUISITE...`
  - `hive stack TARGET --clear`
- **Options:** `--on`, `--clear`, `--project`, `--json`, `--context`
- **Output:** Text dependency summary, or single-document JSON (`hive-stack.v1`, [schemas/hive-stack.v1.json](../schemas/hive-stack.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` prerequisite link(s) set or cleared, `64` unknown task, cyclic/finished prerequisite refusal, or neither/both of `--on` and `--clear`, `70` storage failure, `75` task lock contention, `78` config error.
- **Effects and approvals:** Updates `TARGET`'s prerequisite task metadata under the task lock so daemon admission waits until prerequisites settle (`--on` is repeatable; `--clear` removes prerequisites).
- **Example:** `hive stack feature-b --on feature-a --json`

### `hive status`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive status`
- **Modes:**
  - **Mode `running`** (condition: `no --operational and no --diagnose`; options: `--project`, `--json`, `--context`): Local default polls bounded daemon health and identity-verified live tasks (`hive-running-status.v2`, with explicit scan/output truncation). Under a remote context, GETs `/status` (accepting `--project` and remote-only `--cursor HANDLE` pagination; note R12 follow-up: `--cursor` is accepted by remote preflight but not declared on local Thor `Hive::CLI#status`) and emits `hive-remote.v1`.
  - **Mode `operational`** (condition: `--operational`; options: `--operational`, `--project`, `--json`, `--context`): Local-only inspection of the active workflow queue, blocker ownership, cooldowns, and fresh safe next actions (`hive-operational-status.v5`). Rejected under a remote context before any HTTP request with exit `64` (`remote status does not support --operational; use status --json or --context local`).
  - **Mode `diagnose`** (condition: `--diagnose SLUG without --write`; options: `--diagnose`, `--project`, `--stage`, `--json`, `--context`): Local-only read-only diagnostic bundle for one task (`hive-status-diagnose.v2`). Rejected under a remote context with exit `64`.
  - **Mode `diagnose_write`** (condition: `--diagnose SLUG --write`; options: `--diagnose`, `--write`, `--force`, `--project`, `--stage`, `--json`, `--context`): Local-only diagnostic capture that persists the diagnostic artifact for `SLUG` (`--force` overwrites an existing diagnostic file) and emits `hive-status-diagnose.v2`. Rejected under a remote context with exit `64`.
- **Options:** `--operational`, `--diagnose`, `--project`, `--stage`, `--write`, `--force`, `--json`, `--context`
- **Output:** Human-readable tables/reports, or single-document JSON per mode and context: locally `hive-running-status.v2` ([schemas/hive-running-status.v2.json](../schemas/hive-running-status.v2.json)), `hive-operational-status.v5` ([schemas/hive-operational-status.v5.json](../schemas/hive-operational-status.v5.json)), or `hive-status-diagnose.v2` ([schemas/hive-status-diagnose.v2.json](../schemas/hive-status-diagnose.v2.json)); if error-envelope serialization raises `JSON::GeneratorError`, `status` suppresses that serialization failure (`:suppress`) and preserves the original typed command error. Remotely emits `hive-remote.v1` ([schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json)) on both success and failure.
- **Context behavior:** Local supports all four modes (`running`, `operational`, `diagnose`, `diagnose_write`). Remote supports only `running` status (with `--project` and remote `--cursor`); `--operational`, `--diagnose`, `--stage`, `--write`, and `--force` fail closed with exit `64` before any network request.
- **Exits and retry:** `0` status reported (safe read-only polling except `diagnose_write`), `64` incompatible mode flags, remote `--operational` or local-only flags, or unknown `--diagnose` task, `69` remote server unreachable, `70` storage/internal failure, `78` malformed config.
- **Effects and approvals:** `running`, `operational`, and `diagnose` are read-only; `diagnose_write` writes diagnostic output into the task folder (requiring `--force` to replace an existing file).
- **Example:** `hive status --operational --project demo --json`

### `hive task`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `supported_remote`
- **Signatures:**
  - `hive task TARGET`
- **Options:** `--project`, `--log`, `--diff`, `--artifacts`, `--artifact`, `--output`, `--json`, `--context`
- **Output:** Locally, text workspace summary or success-only single-document JSON (`hive-task-workspace.v2`, [schemas/hive-task-workspace.v2.json](../schemas/hive-task-workspace.v2.json) on success; local failures print to stderr without a JSON error envelope). Remotely, prints selected content/JSON or emits single-document JSON (`hive-remote.v1`, [schemas/hive-remote.v1.json](../schemas/hive-remote.v1.json)) on both success and failure.
- **Context behavior:** Local accepts `--project` and `--log` and refuses remote-only selectors (`--diff`, `--artifacts`, `--artifact`, `--output`) before runtime with exit `64` (`these task selectors require --context <remote>; use the local hive task TARGET --json artifact panel`). Remote accepts `--project` and at most one content selector (`--log`, `--diff`, `--artifacts`, or `--artifact ID`), plus `--output PATH` (which requires a content selector and performs an explicit local binary file write to `PATH`).
- **Exits and retry:** `0` inspected (and written when remote `--output PATH` is given), `64` unknown task, multiple content selectors, local use of remote-only selectors, `--output` without a selector, or unwritable `--output` destination, `69` remote transport error, `70` read error.
- **Effects and approvals:** Read-only except when remote `--output PATH` explicitly writes the fetched log/diff/artifact bytes to local `PATH`.
- **Example:** `hive task demo:my-task --artifact report --output ./report.txt --context prod`

### `hive token`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Token#call literal when branches (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/token.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#token help (R12)`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive token`
- **Options:** `--json`, `--context`
- **Output:** Defaults to `token list`: text table of server-local API tokens (public ID, name, scopes, projects, expiry, status; never secrets), or single-document JSON (`hive-token.v1`, [schemas/hive-token.v1.json](../schemas/hive-token.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`. Local preflight rejects any accidental literal bearer (`24hex.64hex`) in argv before Thor can echo it (`64`).
- **Exits and retry:** `0` listed, `64` invalid flags or accidental literal bearer in argv, `70` storage error, `78` config error.
- **Effects and approvals:** Read-only.
- **Example:** `hive token --json`

### `hive token create`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Token#call literal when branches (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/token.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#token help (R12)`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive token create`
- **Options:** `--scopes`, `--projects`, `--all-projects`, `--name`, `--expires-at`, `--json`, `--context`
- **Output:** Displays the newly minted bearer token once alongside its public ID and limits in text, or single-document JSON (`hive-token.v1`, [schemas/hive-token.v1.json](../schemas/hive-token.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` token minted (not idempotent: each call creates a new token), `64` unexpected positional `ID`, invalid `--scopes`/`--projects`/`--expires-at`, or conflicting `--projects` + `--all-projects`, `70` storage error.
- **Effects and approvals:** Persists a hashed server-local API token record in runtime storage and prints the plaintext secret once for operator capture via `hive context add --token-stdin`.
- **Example:** `hive token create --name ci-reader --scopes read --all-projects --json`

### `hive token list`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Token#call literal when branches (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/token.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#token help (R12)`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive token list`
- **Options:** `--json`, `--context`
- **Output:** Text table of server-local API token metadata (never secrets), or single-document JSON (`hive-token.v1`, [schemas/hive-token.v1.json](../schemas/hive-token.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed, `64` unexpected positional `ID` or creation-only flags, `70` storage error.
- **Effects and approvals:** Read-only.
- **Example:** `hive token list --json`

### `hive token revoke`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `checked_exception`
- **Evidence:** `catalog_declared_with_exception`
- **Exception:** field=`selector_discovery`; evidence=`Commands::Token#call literal when branches (no named registry or structured synopsis in Thor help)`; owner=`lib/hive/commands/token.rb`; follow_up=`Expose a named selector registry or structured synopsis rows in Hive::CLI#token help (R12)`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive token revoke ID`
- **Options:** `--json`, `--context`
- **Output:** Text revocation confirmation, or single-document JSON (`hive-token.v1`, [schemas/hive-token.v1.json](../schemas/hive-token.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`. Preflight verifies `ID` matches the 24-hex public token ID grammar and rejects full bearer secrets (`64`).
- **Exits and retry:** `0` revoked (idempotent if already revoked), `64` missing/malformed public `ID`, literal bearer passed, or creation-only flags passed, `70` storage error.
- **Effects and approvals:** Marks the identified server-local API token revoked so subsequent remote bearer requests fail authentication.
- **Example:** `hive token revoke 0123456789abcdef01234567 --json`

### `hive tree`

- **Aliases:** `--tree`, `-t`
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive tree`
- **Options:** `--json`, `--context`
- **Output:** Human-readable Thor command tree; `--json` is ignored (text-only).
- **Context behavior:** Runs client-side regardless of active `--context`.
- **Exits and retry:** `0` always.
- **Effects and approvals:** Read-only.
- **Example:** `hive tree`

### `hive tui`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive tui`
- **Options:** `--json`, `--context`
- **Output:** Interactive terminal UI; explicitly rejects `--json` with exit `64` and a schema-less JSON error document rather than starting the TUI.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` exited normally from TUI, `64` `--json` supplied or non-TTY terminal unable to host the TUI, `70` internal error.
- **Effects and approvals:** Interactive operator dashboard that can dispatch task actions only on explicit operator keystrokes.
- **Example:** `hive tui`

### `hive uninstall`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive uninstall`
- **Options:** `--purge`, `--force-purge-state`, `--json`, `--context`
- **Output:** Human-readable removal log; `--json` is ignored (text-only).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` user registrations/services/runtime files removed, `64` invalid flags or unsafe purge rejected, `70` service/filesystem error, `78` malformed config.
- **Effects and approvals:** Stops and removes per-user Hive services, global registrations, and runtime files without destroying project work; `--purge` removes global config/state, and `--force-purge-state` overrides state-safety guards.
- **Example:** `hive uninstall`

### `hive update`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive update`
- **Options:** `--dry-run`, `--json`, `--context`
- **Output:** Human-readable install-channel update progress and runtime validation output; `--json` is ignored (text-only).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` up to date, dry-run printed, or updated cleanly, `69` network/channel unavailable, `70` upgrade command failed, `78` unknown install channel or incompatible runtime storage.
- **Effects and approvals:** Updates Hive via the channel that installed it (Homebrew, RubyGems, installer, or source checkout) and validates current runtime storage; `--dry-run` performs no upgrade.
- **Example:** `hive update --dry-run`

### `hive version`

- **Aliases:** `--version`, `-v`
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `context_management`
- **Signatures:**
  - `hive version`
- **Options:** `--json`, `--context`
- **Output:** Plain-text Hive version string, or single-document JSON (`hive-version.v1`, [schemas/hive-version.v1.json](../schemas/hive-version.v1.json)) on success and usage error.
- **Context behavior:** Runs client-side regardless of active `--context` and works before local Hive setup.
- **Exits and retry:** `0` version text or the v1 JSON document emitted, `1` JSON serialization failed before a document could be emitted, `64` the `version` invocation was malformed.
- **Effects and approvals:** Read-only.
- **Example:** `hive version --json`

### `hive watch`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `top_level`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive watch [TARGET...]`
- **Options:** `--project`, `--until`, `--timeout`, `--interval`, `--max-events`, `--json-lines`, `--json`, `--context`
- **Output:** Human-readable semantic transition stream, or JSON Lines via `--json-lines` emitting one `hive-watch-event.v1` ([schemas/hive-watch-event.v1.json](../schemas/hive-watch-event.v1.json)) JSON object per line. Explicitly rejects inherited `--json` with exit `64`, empty stdout, and stderr guidance pointing callers to `--json-lines`.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` `--until` target state reached (`settled` by default) or bounded event limit reached cleanly, `64` `--json` passed instead of `--json-lines` or invalid target/interval/timeout/until values, `70` observation error, `75` `--timeout` expired before target state settled (retryable).
- **Effects and approvals:** Strictly read-only polling observer (defaults: `--interval 15`, `--timeout 1800`, `--max-events 100`, `--until settled`).
- **Example:** `hive watch demo:my-task --until settled --json-lines`

### `hive web`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web`
- **Options:** `--bind`, `--port`, `--no-bootstrap`, `--unsafe`, `--allow-public`, `--json`, `--context`
- **Output:** Foreground Rails web UI server logs; explicitly rejects `--json` with exit `64` and a `hive-web-status.v1` ([schemas/hive-web-status.v1.json](../schemas/hive-web-status.v1.json)) error envelope.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` foreground server exited cleanly, `64` `--json` passed, invalid bind/port, or non-loopback bind without configured owner and without `--unsafe`/`--allow-public`, `70` bootstrap or Rails startup failure, `75` port/service contention, `78` config error.
- **Effects and approvals:** Bootstraps the managed web app (unless `--no-bootstrap`) and runs Hive Web in the foreground (blocking); non-loopback binds without configured owner require `--unsafe` (or alias `--allow-public`).
- **Example:** `hive web --port 4567`

### `hive web capture`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web capture`
- **Options:** `--task-folder`, `--source-root`, `--json`, `--context`
- **Output:** Human-readable capture summary, or single-document JSON (`hive-artifact-capture.v2`, [schemas/hive-artifact-capture.v2.json](../schemas/hive-artifact-capture.v2.json)) when `--json` is passed.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` capture completed, `64` missing/invalid `--task-folder` or dirty `--source-root`, `70` capture execution failure.
- **Effects and approvals:** Captures release/UI evidence artifacts for an artifacts-stage `--task-folder` from an exact clean `--source-root` worktree.
- **Example:** `hive web capture --task-folder .hive-state/stages/7-artifacts/my-task --source-root . --json`

### `hive web capture-server`

- **Aliases:** none
- **Support:** `visible_internal`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web capture-server`
- **Options:** `--source-root`, `--runtime-root`, `--control-fd`, `--lifecycle-token`, `--json`, `--context`
- **Output:** Always emits a single-document readiness/lifecycle JSON line (`hive-web-capture-runtime.v1`, [schemas/hive-web-capture-runtime.v1.json](../schemas/hive-web-capture-runtime.v1.json)) on stdout; inherited `--json` is accepted without changing the contract.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` capture server exited cleanly after control-fd close, `64` missing/invalid `--source-root`, `--runtime-root`, `--control-fd`, or `--lifecycle-token`, `70` server boot failure.
- **Effects and approvals:** Runs an isolated ephemeral Rails capture server bound to the recorder's private `--runtime-root` and inherited `--control-fd`.
- **Example:** `hive web capture-server --source-root /path/to/repo --runtime-root /tmp/cap --control-fd 3 --lifecycle-token tok_1`

### `hive web install`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web install`
- **Options:** `--force`, `--json`, `--context`
- **Output:** Human-readable installation status, or single-document JSON (`hive-web-install.v1`, [schemas/hive-web-install.v1.json](../schemas/hive-web-install.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` installed, upgraded, unchanged, or unsupported manager, `64` drifted existing service unit without `--force` (retry with `--force`) or invalid arguments, `70` service-manager or bundle install failure, `78` config error.
- **Effects and approvals:** Installs or refreshes the managed web bundle and per-user web service unit; `--force` refreshes the managed bundle and overwrites a differing unit after saving a backup.
- **Example:** `hive web install --force --json`

### `hive web start`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web start`
- **Modes:**
  - **Mode `foreground`** (condition: `without --detach`; options: `--bind`, `--port`, `--no-bootstrap`, `--unsafe`, `--allow-public`, `--json`, `--context`): Bootstraps (unless `--no-bootstrap`) and runs Hive Web in the foreground (blocking), identical to bare `hive web`.
  - **Mode `detached`** (condition: `--detach`; options: `--detach`, `--json`, `--context`): Starts the managed per-user web service in the background via the platform service adapter rather than blocking in the foreground.
- **Options:** `--bind`, `--port`, `--no-bootstrap`, `--unsafe`, `--allow-public`, `--detach`, `--json`, `--context`
- **Output:** Human-readable startup output; explicitly rejects `--json` in both modes with exit `64` and a `hive-web-status.v1` ([schemas/hive-web-status.v1.json](../schemas/hive-web-status.v1.json)) error envelope.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` foreground server exited cleanly or managed service started, `64` `--json` passed, invalid bind/port, or unauthorized public bind, `70` startup or service-manager failure, `75` port/service contention.
- **Effects and approvals:** Starts Hive Web either directly in the foreground or via the managed user service (`--detach`); non-loopback foreground binds require configured owner or `--unsafe`/`--allow-public`.
- **Example:** `hive web start --detach`

### `hive web status`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web status`
- **Options:** `--json`, `--context`
- **Output:** Human-readable web service and readiness summary, or single-document JSON (`hive-web-status.v1`, [schemas/hive-web-status.v1.json](../schemas/hive-web-status.v1.json)) keeping `mode`, effective `url`, compatibility `warnings`, and service installed/enabled/running/readiness distinct.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` status reported, `64` invalid arguments, `70` probe error, `78` malformed config.
- **Effects and approvals:** Strictly read-only observation without mutation or bootstrap.
- **Example:** `hive web status --json`

### `hive web stop`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `registry_expanded_placeholder`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive web stop`
- **Options:** `--json`, `--context`
- **Output:** Human-readable stop confirmation; explicitly rejects `--json` with exit `64` and a `hive-web-status.v1` ([schemas/hive-web-status.v1.json](../schemas/hive-web-status.v1.json)) error envelope.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` managed web service stopped or already stopped (idempotent), `64` `--json` passed or invalid arguments, `70` service-manager stop error.
- **Effects and approvals:** Stops the managed per-user Hive Web service.
- **Example:** `hive web stop`

### `hive wiki compile-log`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive wiki compile-log [PROJECT_PATH]`
- **Options:** `--check`, `--json`, `--context`
- **Output:** Human-readable log-compilation status; `--json` is ignored (text-only).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` `wiki/log.md` rebuilt or verified up to date (`--check`), `1` `--check` detected out-of-date `wiki/log.md`, `64` invalid project path or subcommand, `70` filesystem error.
- **Effects and approvals:** Without `--check`, deterministically rebuilds `wiki/log.md` from `wiki/log.d/*.md` fragments plus legacy log body; `--check` is read-only.
- **Example:** `hive wiki compile-log --check`

### `hive workflow`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow`
- **Options:** `--json`, `--context`
- **Output:** Usage error on stderr listing workflow subcommands (`new`, `validate`, `commit`, `install`, `list`, `update`, `remove`, `publish`), or JSON error envelope when `--json` is passed.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND`.
- **Effects and approvals:** No side effects.
- **Example:** `hive workflow list --json`

### `hive workflow commit`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow commit ID`
- **Options:** `--json`, `--context`
- **Output:** Human-readable commit confirmation; explicitly rejects `--json` with exit `64` (`workflow commit does not support --json`).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` validated workflow committed, `64` missing/invalid `ID`, validation failure, or `--json` passed, `70` git commit failure, `75` state commit lock contention, `78` config error.
- **Effects and approvals:** Validates the owner-authored descriptor and instruction files for `ID` and commits them on `hive/state` under Hive's state commit lock.
- **Example:** `hive workflow commit editorial`

### `hive workflow install`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow install honeycomb/NAME[@VERSION]`
  - `hive workflow install ID --from REPOSITORY`
- **Options:** `--from`, `--ref`, `--dry-run`, `--yes`, `--mapping`, `--input-binding`, `--allow-escalation`, `--json`, `--context`
- **Output:** Text verification/install summary, or single-document JSON (`hive-workflow-install.v2`, [schemas/hive-workflow-install.v2.json](../schemas/hive-workflow-install.v2.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed (`--dry-run`) or installed, `64` invalid package/ID, mixing Git `--from`/`--ref` with managed `--mapping`/`--input-binding`, missing `--yes` in non-TTY/JSON mode, or unapproved escalation without `--allow-escalation`, `69` registry or Git remote unreachable, `70` verification/install failure, `78` config error.
- **Effects and approvals:** Form 1 verifies and atomically installs a reviewed Honeycomb package (supporting `--mapping`, `--input-binding`, `--allow-escalation`). Form 2 imports an owner-selected authored workflow from Git (`--from REPOSITORY`, optional `--ref`, default `HEAD`). `--dry-run` validates without state writes; non-TTY/JSON installs require `--yes`.
- **Example:** `hive workflow install honeycomb/editorial --dry-run --json`

### `hive workflow list`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow list`
- **Options:** `--json`, `--context`
- **Output:** Text table of built-in, authored, managed, selected, and retained workflows, or single-document JSON (`hive-workflow-list.v2`, [schemas/hive-workflow-list.v2.json](../schemas/hive-workflow-list.v2.json)) including integrity/provenance, active managed configuration, and redacted input availability.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` listed, `64` unexpected positional `ID` or invalid flags, `78` malformed project workflow state.
- **Effects and approvals:** Strictly read-only.
- **Example:** `hive workflow list --json`

### `hive workflow new`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow new ID`
- **Options:** `--template`, `--json`, `--context`
- **Output:** Text scaffold paths, or single-document JSON (`hive-workflow-new.v1`, [schemas/hive-workflow-new.v1.json](../schemas/hive-workflow-new.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` scaffolded, `64` missing/invalid `ID`, duplicate workflow, or unknown `--template`, `78` symlinked or invalid scaffold root.
- **Effects and approvals:** Creates `<hive_state_path>/workflows/<ID>.yml` and stage instructions under `<hive_state_path>/workflows/<ID>/` (blank `inbox -> work -> done` stub by default, or seeded from `--template NAME`).
- **Example:** `hive workflow new research-loop --template research --json`

### `hive workflow publish`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow publish ID`
- **Options:** `--version`, `--dry-run`, `--expected-release-digest`, `--json`, `--context`
- **Output:** Text build/publish summary, or single-document JSON (`hive-workflow-publish.v2`, [schemas/hive-workflow-publish.v2.json](../schemas/hive-workflow-publish.v2.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` dry-run built/linted or release submitted/reconciled, `64` missing/invalid `--version`, missing or mismatched `--expected-release-digest` for live publish, or security-lint failure, `69` GitHub/registry unreachable, `70` package build or PR failure.
- **Effects and approvals:** `--dry-run` builds, consumer-validates, and security-lints the immutable Honeycomb package with no remote or receipt effects and emits the release digest; live publish requires `--expected-release-digest SHA256` and opens a Honeycomb registry PR.
- **Example:** `hive workflow publish editorial --version 1.0.0 --dry-run --json`

### `hive workflow remove`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow remove NAME`
- **Options:** `--dry-run`, `--yes`, `--json`, `--context`
- **Output:** Text confirmation, or single-document JSON (`hive-workflow-remove.v1`, [schemas/hive-workflow-remove.v1.json](../schemas/hive-workflow-remove.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed (`--dry-run`) or removed, `64` unknown managed package `NAME`, active unfinished tasks still owned by `NAME`, or missing `--yes` in non-TTY/JSON mode, `70` storage error, `75` state lock contention.
- **Effects and approvals:** Disables a managed workflow package for new tasks once all owned tasks are finished, archived, or reset; non-TTY/JSON removal requires `--yes`.
- **Example:** `hive workflow remove editorial --dry-run --json`

### `hive workflow update`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow update NAME`
- **Options:** `--dry-run`, `--yes`, `--mapping`, `--input-binding`, `--allow-escalation`, `--json`, `--context`
- **Output:** Text semantic/security diff and result, or single-document JSON (`hive-workflow-update.v2`, [schemas/hive-workflow-update.v2.json](../schemas/hive-workflow-update.v2.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` previewed (`--dry-run`) or updated, `64` unknown managed package, missing `--yes` in non-TTY/JSON mode, or increased/unbounded capabilities without `--allow-escalation`, `69` registry unreachable, `70` update failure.
- **Effects and approvals:** Computes a semantic/security diff for managed package `NAME` and atomically advances it after consent (`--yes`, plus `--allow-escalation` when capabilities increase); `--dry-run` makes no writes.
- **Example:** `hive workflow update editorial --dry-run --json`

### `hive workflow validate`

- **Aliases:** none
- **Support:** `stable`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive workflow validate ID`
- **Options:** `--json`, `--context`
- **Output:** Text validation diagnostics, or single-document JSON (`hive-workflow-validate.v1`, [schemas/hive-workflow-validate.v1.json](../schemas/hive-workflow-validate.v1.json)) on success and error.
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` normalized workflow graph and instructions are valid, `64` missing/invalid `ID` or descriptor/instruction validation failure, `78` malformed project config.
- **Effects and approvals:** Strictly read-only.
- **Example:** `hive workflow validate editorial --json`

### `hive worktree`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive worktree`
- **Options:** `--json`, `--context`
- **Output:** Usage error on stderr listing worktree subcommands (`status`, `commit-residue`, `discard-residue`, `repair`), or single-document JSON (`hive-worktree.v1`, [schemas/hive-worktree.v1.json](../schemas/hive-worktree.v1.json), `:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `64` missing required `SUBCOMMAND`.
- **Effects and approvals:** No side effects.
- **Example:** `hive worktree status my-task --json`

### `hive worktree commit-residue`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive worktree commit-residue TARGET`
- **Options:** `--project`, `--stage`, `--message`, `--complete-execute`, `--json`, `--context`
- **Output:** Text commit summary, or single-document JSON (`hive-worktree.v1`, [schemas/hive-worktree.v1.json](../schemas/hive-worktree.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` residue committed, `4` task lacks an admitted `ensure_clean_on_exit_failed` or `dirty_worktree` recovery marker, `64` invalid target, scope/safety failure, or bad `--message`, `70` git failure, `75` task lock contention.
- **Effects and approvals:** Scope-checks, safety-checks, and commits worktree residue under the task lock (never clears the recovery marker directly: refresh `hive status --operational --json` and invoke generation-guarded `workflow.retry`). `--complete-execute` completes a validated `4-execute` dirty-residue recovery.
- **Example:** `hive worktree commit-residue my-task --message "Save execute output" --json`

### `hive worktree discard-residue`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive worktree discard-residue TARGET`
- **Options:** `--project`, `--stage`, `--paths`, `--json`, `--context`
- **Output:** Text discard summary, or single-document JSON (`hive-worktree.v1`, [schemas/hive-worktree.v1.json](../schemas/hive-worktree.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` residue discarded, `4` task lacks an admitted dirty-worktree recovery marker, `64` invalid target or out-of-scope `--paths`, `70` git failure, `75` task lock contention.
- **Effects and approvals:** Destructively discards only `--paths` or marker-recorded residue under the task lock without clearing the recovery marker directly.
- **Example:** `hive worktree discard-residue my-task --paths tmp/scratch.txt --json`

### `hive worktree repair`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive worktree repair TARGET`
- **Options:** `--project`, `--stage`, `--strategy`, `--message`, `--paths`, `--complete-execute`, `--json`, `--context`
- **Output:** Text repair summary, or single-document JSON (`hive-worktree.v1`, [schemas/hive-worktree.v1.json](../schemas/hive-worktree.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` residue repaired via `--strategy`, `4` task lacks an admitted dirty-worktree recovery marker, `64` invalid `--strategy` (must be `commit` or `discard`) or bad options, `70` git failure, `75` task lock contention.
- **Effects and approvals:** Runs `commit-residue` or `discard-residue` via `--strategy` under the task lock without clearing the recovery marker directly.
- **Example:** `hive worktree repair my-task --strategy commit --message "Keep verified work" --json`

### `hive worktree status`

- **Aliases:** none
- **Support:** `maintenance`
- **Coverage:** `full`
- **Evidence:** `structured_synopsis`
- **Context posture:** `local_only`
- **Signatures:**
  - `hive worktree status TARGET`
- **Options:** `--project`, `--stage`, `--json`, `--context`
- **Output:** Exact porcelain residue listing in text, or single-document JSON (`hive-worktree.v1`, [schemas/hive-worktree.v1.json](../schemas/hive-worktree.v1.json)) on success and error (`:raise` serialization policy).
- **Context behavior:** Local only; remote context exits `64`.
- **Exits and retry:** `0` inspected, `64` unknown/ambiguous `TARGET`, `70` git inspection error.
- **Effects and approvals:** Strictly read-only inspection without writes.
- **Example:** `hive worktree status my-task --json`

## Excluded Hidden and Private Routes

Verified hidden Thor commands, hidden Thor options, and pre-Thor wrapper routes are excluded from the public catalog and carry `support: private`. Exposing any entry below in visible `bin/hive help` fails parity until it is removed from this exclusion inventory and given a full public catalog record.

### Hidden Commands

- `__patrol-fix-semantic-decision` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal patrol-fix semantic decision worker)
- `refactor-patrol-classify` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal architecture-patrol merge classifier)
- `refactor-patrol-scheduled` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal scheduled architecture-patrol entrypoint)

### Hidden Options

- `bot --detach` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` legacy compatibility flag on bot start)
- `proposal --compile-only` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal pinned compiler flag for managed proposal refresh worktree)
- `proposal --output-root` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal pinned compiler output directory flag)
- `proposal --source-ref` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal pinned compiler source-ref flag)
- `status --daemon-task` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal daemon single-task status projection flag)
- `status --internal-task-graph` (support: `private`; source: `lib/hive/cli.rb`; reason: Thor `hide: true` internal daemon task-graph projection flag)

### Private Pre-Thor Routes

- `__attempt-supervise` (support: `private`; source: `bin/hive`; reason: Pre-Thor internal durable attempt supervision route intercepted in bin/hive)
- `__module-hook` (support: `private`; source: `bin/hive`; reason: Pre-Thor internal module hook execution route intercepted in bin/hive)
