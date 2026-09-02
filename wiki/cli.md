---
title: CLI Surface
type: api
source: bin/hive, bin/hive-e2e, bin/hv, lib/hive/cli.rb, lib/hive/runtime_identity.rb, lib/hive/cli_argv_policy.rb
created: 2026-04-25
updated: 2026-09-02
tags: [cli, api, skills, agents, operational, provisioning, brainstorm, plan-review]
---

**TLDR**: Hive exposes a Thor CLI through `hive`, plus the `hv` collision
fallback. Rendered `hive help` defines the visible command surface; the index
below maps every visible top-level token to exactly one authoritative command
or module owner. This page owns only shared wrapper, exit, and error
conventions.

## Entry point

`bin/hive` is a thin runner that loads `lib/hive` and calls `Hive::CLI.start(ARGV)`, catching `Hive::Error` to render `hive: <message>` to stderr with the error's `exit_code` (default `ExitCodes::GENERIC = 1`).

Before Thor dispatch, `bin/hive` delegates its shared wrapper grammar to the
pure `Hive::CliArgvPolicy`. The wrapper validates every argument as UTF-8,
handles exact top-level `--version` / `-v`, rewrites command-local `--help` /
`-h` to `help COMMAND`, and normalizes Thor's exact JSON boolean spellings.
The last recognized JSON boolean wins. Unsupported assignments such as
`--json=1` and `--json=yes` fail as usage errors rather than becoming command
arguments.

The global `--json` grammar does not imply that every command publishes JSON.
The linked owner page defines whether a command accepts, rejects, or ignores
that option and owns any command-specific wrapper transformation, schema,
error vocabulary, and serialization fallback. Pre-dispatch Thor failures use
the selected command's owner-defined error surface when one exists; otherwise
they remain human usage text. Option values and tokens after `--` cannot
impersonate subcommands during that selection.

`bin/hv` is a bash fallback launcher for Apache Hive name collisions. It deliberately avoids `command -v hive`; instead it probes only `HIVE_BIN_OVERRIDE`, `${XDG_BIN_HOME:-$HOME/.local/bin}/hive`, `${HOMEBREW_PREFIX:-/opt/homebrew}/bin/hive`, and `/usr/local/bin/hive`, skipping a target that resolves back to itself. Each `--version` probe runs in its own process group with temp-file stdout capture and a watchdog/KILL sweep, so a bad candidate cannot keep `hv` blocked by forking a stdout-inheriting child. When the watchdog's timeout elapses it records a sentinel, and `probe_version` forces a non-zero (124, mirroring GNU `timeout`) status regardless of the probe's own exit code — so a candidate that prints a bare semver and then hangs (trapping the watchdog's TERM to exit 0) is rejected rather than exec'd. It does not implicitly exec `/usr/bin/hive` or `/opt/hive/bin/hive`, because those paths may be Apache Hive installs. If no candidate is executable it exits `127` and tells the operator to set `HIVE_BIN_OVERRIDE` or install through the documented channels. `bin/hv` remains in the gem payload for channel installers to copy/read, but it is not listed in `spec.executables`; RubyGems would otherwise generate a Ruby binstub for this bash launcher. See [[operating]] for channel-level `hv` behavior.

## Command index

Rendered `hive help` defines the visible public top-level command set. This
index is navigation only: each canonical first command token has exactly one
row and one owner link. The linked owner is authoritative for command syntax,
options, behavior, examples, schemas, output/error exceptions, serialization
fallback, and exit codes. Supporting module or stage links belong inside that
owner page, never as competing links here.

| Command | Owner |
|---|---|
| `hive accept-finding` | [[commands/findings]] |
| `hive act` | [[commands/status]] |
| `hive answer` | [[commands/answer]] |
| `hive answer-digest` | [[commands/answer-digest]] |
| `hive approve` | [[commands/approve]] |
| `hive archive` | [[commands/stage_action]] |
| `hive artifacts` | [[commands/stage_action]] |
| `hive babysit` | [[commands/babysit]] |
| `hive bench` | [[commands/bench-submit]] |
| `hive bot` | [[commands/bot]] |
| `hive brainstorm` | [[commands/stage_action]] |
| `hive circuits` | [[commands/circuits]] |
| `hive connect` | [[commands/screenote]] |
| `hive daemon` | [[commands/daemon]] |
| `hive decide` | [[commands/workflow]] |
| `hive develop` | [[commands/stage_action]] |
| `hive disconnect` | [[commands/screenote]] |
| `hive doctor` | [[commands/doctor]] |
| `hive drop` | [[commands/drop]] |
| `hive evidence` | [[commands/evidence]] |
| `hive finalize` | [[commands/stage_action]] |
| `hive findings` | [[commands/findings]] |
| `hive forget` | [[commands/forget]] |
| `hive generate-name` | [[commands/generate-name]] |
| `hive help` | [[commands/help]] |
| `hive init` | [[commands/init]] |
| `hive markers` | [[commands/markers]] |
| `hive metrics` | [[commands/metrics]] |
| `hive migrate` | [[commands/migrate]] |
| `hive module` | [[commands/module]] |
| `hive new` | [[commands/new]] |
| `hive open-pr` | [[commands/stage_action]] |
| `hive pairing` | [[commands/pairing]] |
| `hive patrol` | [[commands/patrol]] |
| `hive plan` | [[commands/stage_action]] |
| `hive plan-review` | [[modules/plan_review]] |
| `hive plan-review-run` | [[modules/plan_review]] |
| `hive prune` | [[commands/prune]] |
| `hive rebase-status` | [[commands/rebase-status]] |
| `hive refactor-patrol` | [[commands/refactor-patrol]] |
| `hive reject-finding` | [[commands/findings]] |
| `hive review` | [[commands/stage_action]] |
| `hive run` | [[commands/run]] |
| `hive runtime` | [[commands/runtime]] |
| `hive setup` | [[commands/setup]] |
| `hive setup-agents` | [[commands/setup-agents]] |
| `hive status` | [[commands/status]] |
| `hive task` | [[commands/task]] |
| `hive tree` | [[commands/tree]] |
| `hive tui` | [[commands/tui]] |
| `hive uninstall` | [[commands/uninstall]] |
| `hive update` | [[commands/update]] |
| `hive version` | [[commands/version]] |
| `hive watch` | [[commands/watch]] |
| `hive web` | [[commands/web]] |
| `hive wiki` | [[commands/wiki]] |
| `hive workflow` | [[commands/workflow]] |
| `hive worktree` | [[modules/worktree]] |

Aliases do not receive rows unless rendered help exposes them. `pr` maps to the
`open-pr` owner, and exact top-level `--version` / `-v` invocations map to the
`version` owner. Hidden/internal commands are excluded only through explicit
Thor visibility metadata, never by a name pattern.

## Shared dispatch conventions

`Hive::CLI` (`lib/hive/cli.rb`) is the Thor class. Source method keys may use
underscores, while Hive's explicit Thor mappings define public hyphenated
spellings; the ownership guard inverts that map instead of guessing from a
name. `new_task`, `generate_name`, and `run_task` therefore render as `new`,
`generate-name`, and `run`, and `pr` is a non-rendered alias of `open-pr`.

`bin/hive` rewrites `<cmd> --help` / `<cmd> -h` to `help <cmd>` before command
validation, handles exact top-level `--version` / `-v`, and normalizes leading
Thor-style JSON booleans. `--json` is a class option, but support and the exact
contract remain owner-page decisions.

## Shared exit-code contract (`Hive::ExitCodes`)

| Code | Constant | Shared meaning |
|---:|---|---|
| 0 | `SUCCESS` | Command completed. |
| 1 | `GENERIC` | Unclassified failure. |
| 2 | `ALREADY_INITIALIZED` | Requested initialization already exists. |
| 3 | `TASK_IN_ERROR` | A stage completed its runner but recorded an error marker. |
| 4 | `WRONG_STAGE` | The requested transition or action does not match current stage state. |
| 64 | `USAGE` | Invalid arguments or target shape (`EX_USAGE`). |
| 69 | `UNAVAILABLE` | A required service or producer is temporarily unavailable (`EX_UNAVAILABLE`). |
| 70 | `SOFTWARE` | Internal software, Git, worktree, agent, or runner failure (`EX_SOFTWARE`). |
| 75 | `TEMPFAIL` | Retryable contention or stale observation (`EX_TEMPFAIL`). |
| 78 | `CONFIG` | Invalid project, global, provider, or managed configuration (`EX_CONFIG`). |

Codes are stable; changing one requires updating
`test/unit/exit_codes_test.rb`. An owner page lists the exact codes and meanings
for its command rather than relying on this cross-command vocabulary.

## Shared error conventions

`Hive::Error` is the root typed CLI exception. Subclasses provide an
`exit_code`, and `bin/hive` renders `hive: <message>` on stderr before exiting
with that code. `Hive::UsageError` is the generic argv failure;
`Hive::InvalidTaskPath` remains distinct for task/path resolution and for
published compatibility surfaces whose owner contract names that error kind.

Commands that opt into `Hive::Schemas::ErrorEnvelope` share the baseline
`schema`, `schema_version`, `ok: false`, `error_kind`, `exit_code`, and
`message` shape. The owner page is authoritative for whether `error_class` or
structured extras exist, the closed error vocabulary, pre-dispatch routing,
and what happens when JSON serialization itself fails. Failures before the
wrapper can load Hive or inspect argv cannot emit JSON and remain stderr plus
an exit code.

The CLI has no universal authentication or mutation precondition beyond these
wrapper rules. Each owner page documents its own credentials, clean-tree,
consent, registration, state, and service requirements.

## Backlinks

- [[commands]] · [[architecture]] · [[operating]]
