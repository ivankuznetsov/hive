---
title: Agentic E2E Suite
type: reference
source: test/e2e/, bin/hive-e2e, schemas/hive-e2e-{coverage,selection}.v1.json, Rakefile
created: 2026-04-29
updated: 2026-07-31
tags: [test, e2e, tui, incidents, modules, artifacts]
---

**TLDR**: `test/e2e/` is the outer test layer. It drives the real `bin/hive` binary in a copied Ruby sample project, uses tmux for TUI scenarios, validates JSON output against published schemas, and writes versioned run artifacts for later debugging. The `bin/hive-e2e` Thor executable is also a small public harness surface with pinned exit codes and JSON error envelopes for wrapper/CI callers.

## Commands

```bash
bundle exec rake e2e:lib_test   # harness library tests
bin/hive-e2e list               # scenario inventory
bin/hive-e2e run                # all scenarios
bin/hive-e2e run --filter tui   # tag filter
bin/hive-e2e run --filter incident-regression --json
bin/hive-e2e coverage --match "provider retry"
bin/hive-e2e run --coverage workflow.full_pipeline
bin/hive-e2e run --profile release
test/e2e/check_incident_budget.rb test/e2e/runs
bin/hive-e2e clean              # old run cleanup
```

`rake e2e` delegates to `bin/hive-e2e run`. The default `rake test` suite does not run e2e scenarios.

## Semantic coverage

`test/e2e/coverage.yml` is the canonical stable-ID taxonomy for the 24 scenario
files. Each scenario retains its steps, pending state, incident metadata, and
filename as execution authority while declaring one `coverage.primary` and an
initially empty `coverage.supporting` list. The catalog owns titles,
descriptions, `required` / `advisory` / `planned` maturity, release-profile
membership, constraints, and root-confined documentation/code references.
The release profile includes four module proofs for install, event replay,
disable/uninstall watermarks, and update rollback.

`bin/hive-e2e coverage --match QUERY [--profile release] [--json]` searches the
joined catalog and scenario metadata. Exact IDs win; substring results use
stable lexical ID order. Only an active, non-planned primary receives an exact
`run --coverage ID` command. Supporting scenarios are supplemental discovery
results and pending/planned matches remain visible without a runnable command.

`bin/hive-e2e run --profile release` selects the active primary for each
required release ID before constructing a runner. Unknown mappings, duplicate
primary owners, invalid catalog vocabulary/references/profiles, and a required
profile gap fail preflight before run or sandbox creation. Semantic runs write
`selection.json` (`hive-e2e-selection.v1`) beside the unchanged
`report.json` (`hive-e2e-report.v1`); discovery uses
`hive-e2e-coverage.v1`. Plain run, pattern/filter selection, list output, and
the ordinary CI invocation retain their prior contracts.

The published `schemas/hive-e2e-coverage.v1.json` contract binds discovery to
the catalog digest, query/profile, maturity and constraints, primary/supporting
scenario metadata, root-confined references, and optional runnable command.
`schemas/hive-e2e-selection.v1.json` binds a semantic run to its catalog
digest, profile, required coverage IDs, concrete scenarios,
pending/advisory/planned IDs, and replay command. `coverage` is read-only
discovery; `run --coverage` and `run --profile` create the normal run directory
and are the only modes that add `selection.json`.

## Patrol compressed-evidence qualification

The `module_patrol_compressed_evidence` scenario prepares one exact-HEAD,
clean-checkout candidate plus its offline installed runtime, imports that
immutable input set into the production qualification repository, and runs the
deterministic and installed lanes from the imported bytes. The temporary
candidate workspace is removed immediately after a successful import, before
either lane or artifact publication can start. Cleanup holds no-follow
descriptors for every directory, changes permissions only through those
verified descriptors, rejects identity/owner/device/link/type or realpath
drift, uses non-forced removal, and requires the exact workspace root to be
absent afterward. Preparation and cleanup failures remain distinct in the
reported cause chain.

Each successful candidate case is followed by mandatory host-side
reconstruction before its oracle result is accepted. Ordinary cases bind the
raw event, decision, Attempts, evidence, comparator, retirement, and repository
stores. Architecture cases also bind the derived manifest identity, complete
v3 aggregate, all transition receipts, action outcomes, deterministic event
envelope, and exact retirement generation. Candidate-reported process counts,
fault checkpoints, and timed state digests remain unverified until the host
controller supervises separate process generations.

Coverage keeps diagnostic progress separate from qualification authority.
`module.patrol_compressed_evidence_diagnostic` is advisory and explicitly
runnable: it accepts either local same-candidate `evidence_required` evidence
or independent deterministic-only evidence while the installed lane remains
unauthorized. The required release ID,
`module.patrol_compressed_evidence`, accepts only
`evidence_ready_for_operator` with no blockers, an authenticated independent
`trusted_remote` control on protected main, and passed deterministic and
installed lanes. Release-profile selection records the advisory ID but does
not run it or count it as required proof. The installed lane remains a
retryable diagnostic until a host-owned provider broker can use the descriptor's
OpenRouter binding without exposing the credential or network to candidate
code.

## Binary contract

`bin/hive-e2e` mirrors the main Hive CLI's sysexits-shaped contract for the e2e harness:

| Code | Meaning |
|------|---------|
| `0` | all selected scenarios passed |
| `1` | one or more scenarios failed, or an unclassified harness error occurred |
| `64` | usage error: unknown command, missing required Thor arguments, unsafe replay path, invalid retention window, or no matching scenarios |
| `78` | preflight/config failure: malformed scenario YAML/definitions, missing `tmux`, missing replay repro artifact, or a replay `repro.sh` that is not a regular executable file |

`asciinema` is optional. When it is missing, too old, or cannot start, TUI
scenarios continue without cast capture; that degraded artifact coverage is not
an exit `78` preflight failure.

Thor is started exactly once with `debug: true` so `Thor::Error` re-raises into the executable's outer rescue instead of taking Thor's built-in human path; a second `Binary.start` call would rerun successful commands and emit duplicate JSON envelopes. That outer rescue maps both human and `--json` usage failures to `64`. With `--json`, usage and preflight failures emit a `hive-e2e-error` envelope on stdout with `ok: false`, `error_kind`, `message`, and `exit_code`; human mode prefixes prose errors with `hive-e2e:` on stderr and exits with the same code. Scenario parse/config failures from both `run` and `list` use `error_kind: "preflight"` and exit `78`, before any scenario executes. Replay artifact failures are split: a missing `repro.sh` emits `error_kind: "missing_repro"`, while an existing but non-executable `repro.sh` emits `error_kind: "unusable_repro"`; both exit `78`. Top-level `--version` / `-v` is intercepted before Thor dispatch so prose callers get only `Hive::VERSION`; `version --json` emits the versioned `hive-e2e-version` envelope.
Successful `--json` commands emit exactly one top-level JSON document on stdout, including `list --json`, `clean --json`, and `version --json`, so wrapper callers can parse stdout directly.

`bin/hive-e2e replay RUN_ID SCENARIO` validates safe run/scenario basenames,
resolves the stored `scenarios/<scenario>/repro.sh` under the selected run
directory, and only `exec`s it when it is both a regular file and executable.
Missing scripts return `error_kind: missing_repro`; existing but unusable
scripts, including symlinked runs roots, scenario directories, and repro
entries (even dangling symlinks, which are a present-but-unusable repro entry
rather than a missing one), return `error_kind: unusable_repro`. Both are
config failures (`78`) and use the `hive-e2e-error` envelope in `--json` mode.

`bin/hive-e2e` is a checkout-only harness entrypoint, not a packaged
`hive-cli` executable. It handles top-level `--version` / `-v` before Thor
dispatch and rewrites command-local `--help` / `-h` before scenario selection.
That keeps help requests non-mutating and preflight-free even when command
options precede the help flag, e.g. `bin/hive-e2e run --filter tui --help`.
When a leading JSON class option precedes command help for a recognized command
(`bin/hive-e2e --json --help run` or `--json -h run`), the JSON flag is dropped
and Thor renders the same human `run` help as `--help run` with exit `0`.
If the help flag is followed by a non-command trailer such as `missing` or an
option-looking token such as `--filter`, the JSON flag is restored so the
usage/no-scenarios path still emits the `hive-e2e-error` envelope.
Leading JSON class options are normalized with the same Thor-style boolean
grammar as `bin/hive`: bare `--json`, exact truthy assignments
(`--json=true`/`TRUE`/`t`/`T`), bare negative forms, and exact false
assignments are moved behind a recognized command, or stripped before top-level
`--help` / `-h` / `--version` / `-v` so those flags remain wrapper requests.
Unsupported assignments such as `--json=1` or `--json=yes` are usage errors
before the value can become the default `run` pattern. Wrapper-owned error
formatting checks the last
recognized JSON boolean flag rather than any truthy flag, so duplicate flags
with a final false form, such as `--json --no-json`, emit the human
`hive-e2e:` stderr path. `ARGV` entries that are not valid UTF-8 are rejected
before those rewrites and before Thor dispatch, regardless of the process
locale, and are reported as usage errors (`64`); JSON callers receive the
normal `hive-e2e-error` envelope with `error_kind: "usage"`.

`clean` also validates separate-form `--retain-days` and
`--retain-failed-days` values before Thor dispatch. A bare retention flag, or
one followed by another option such as `--json` or `--dry-run`, is a usage
error (`64`) and never reaches artifact cleanup; Thor cannot silently reuse the
configured retention default for a malformed destructive invocation. Default
retention overrides are namespaced as `HIVE_E2E_RUNS_RETAIN_DAYS` and
`HIVE_E2E_RUNS_RETAIN_FAILED_DAYS`. The legacy generic
`RUNS_RETAIN_DAYS` / `RUNS_RETAIN_FAILED_DAYS` names remain a compatibility
fallback only when the corresponding namespaced variable and CLI option are
absent; using one prints a deprecation warning on stderr, including in JSON
mode, so stdout remains exactly one parseable document. A namespaced value is
authoritative when both forms are present, preventing a generic process
variable from silently overriding the harness-specific cleanup policy.

## Layout

| Path | Purpose |
|------|---------|
| `test/e2e/lib/` | Harness library: sandbox bootstrap, CLI driver, tmux driver, parser, executor, artifact capture, report writer. |
| `test/e2e/coverage.yml` | Stable semantic coverage taxonomy and release-profile membership. |
| `test/e2e/scenarios/*.yml` | Agent-authorable scenarios using the locked YAML vocabulary. |
| `test/e2e/scenarios/README.md` | Incident metadata, activation lifecycle, sibling index, GitHub scripting, and process-isolation contract. |
| `test/e2e/fixtures/gh` | Run-global, default-deny GitHub CLI shim with no host-binary fallback. |
| `test/e2e/sample-project/` | Tiny Ruby fixture copied into each scenario sandbox. Vendored gems keep bootstrap offline. |
| `test/e2e/runs/` | Gitignored run artifacts. Each run has `report.json` and per-scenario artifact directories. |
| `test/e2e/check_incident_budget.rb` | Report-integrity gate plus below-10s-per-incident and below-30s-aggregate advisory check. |
| `bin/hive-e2e` | Thor shell for run/list/replay/clean. |

## Scenario DSL

Supported step kinds:

- `cli`: run the real `bin/hive` subprocess with `args`, `expect_exit`, optional `env`, `cwd`, and timeout.
- `json_assert`: run a CLI command, parse stdout, validate it against a `schemas/hive-*.json` file, then optionally assert a `pick` path.
- `state_assert`: assert file existence, absence, marker state, substring, or regex match; supports a short timeout for async TUI updates.
- `seed_state`, `write_file`, `register_project`, `ruby_block`: fixture setup escape hatches.
- `tui_expect`, `tui_keys`, `wait_subprocess`: tmux-backed TUI interaction.
- `editor_action`, `log_assert`: narrower fixture helpers for editor/log flows.
- `script_gh`: install an ordered sequence of exact GitHub argv, optional cwd/repository expectations, response JSON/stdout, stderr, and exit status.
- `start_releases_stub`, `spawn_background`, `stop_process`: start controlled release responses and attached, harness-owned process groups for daemon-style scenarios.
- `patrol_evidence`: build, import, execute, and capture the immutable Patrol compressed-evidence qualification run.

Template variables include `{sandbox}`, `{run_home}`, `{project}`, `{slug}`, `{run_id}`, and `{task_dir:<stage>}`.

### Trust boundary

`ruby_block` runs the literal `block:` string through Kernel-level code evaluation against the executor's binding with full process privileges. That string can mutate the outer hive checkout, exec arbitrary commands, and read or rewrite any private state of `StepExecutor`. The trust contract is: anyone who can commit to `test/e2e/scenarios/` can execute arbitrary code at test-runtime. **`ruby_block` changes warrant extra reviewer attention.** Prefer a purpose-built step kind for any pattern used more than once.

### Multi-stage fake-claude dispatch

V1 dispatches per-step via `env:` overrides (`HIVE_FAKE_CLAUDE_WRITE_FILE`, `HIVE_FAKE_CLAUDE_WRITE_CONTENT`). Multi-reviewer-per-invocation queueing is post-v1; see [[gaps]].

### Scenario statuses

Each entry in `report.json#scenarios[]` carries a `status`:

- `passed` — every step ran and asserted cleanly.
- `failed` — at least one step raised; failure artifacts are written under `scenarios/<name>/`.
- `setup_failed` — `Sandbox.bootstrap` raised before any step ran. `failed_step_index` is `null`, `artifacts_dir` is `null`. The aggregate run-level status (`complete` / `partial` / `crashed`) is unaffected.

### Incident metadata and pending fixtures

Scenarios tagged `incident-regression` require a non-empty `description`, a
lowercase-kebab `incident_id`, and a `sibling_task_id` shaped like `#9767`.
`pending: true` is a temporary sibling gate, not a scenario result status. A
selected pending fixture is parsed and included in the additive top-level
`scenario_metadata` array, but its steps do not execute, it contributes no
`scenarios[]` row, and it does not change existing summary counts. A
pending-only run is therefore complete and green with `summary.total: 0`, but
does not claim that any incident passed. Legacy v1 reports without
`scenario_metadata` remain schema-valid.

Activation consumes the sibling task's exact persisted state, terminal state,
and reason code before removing `pending`. Harness fixtures must not infer
those contracts. The scenario README is the canonical six-incident index and
activation checklist.

`list --json` exposes `incident_id`, `sibling_task_id`, and `pending` on every
inventory row (nullable IDs on ordinary scenarios); human list/run output marks
pending fixtures and reports selected, executed, pending, passed, and failed
counts. Incident metadata without the `incident-regression` tag is rejected so
it cannot bypass runtime budgets.

### Hermetic GitHub and agents

`SandboxEnv` puts `test/e2e/fixtures/gh` first on `PATH`, pins the exact require
paths from Bundler's resolved specs as `RUBYLIB` so subprocesses retain the
locked dependency set without inheriting Bundler setup, and pins
`HIVE_GH_BIN` to the same shim for blocking, background, tmux, and replay
subprocesses. `script_gh` interactions are
consumed atomically. An absent or exhausted script, unexpected argv, cwd
mismatch, or repository mismatch exits non-zero and records the rejected call;
the shim never resolves or executes the machine's real `gh`. Thus e2e GitHub
reads and mutations are synthetic and no real network access is possible.
Git commands without `--repo`/`GH_REPO` derive a normalized identity from the
checkout origin and record that provenance. One ordered script is allowed per
scenario, the audit is append-only, and background plus tmux/TUI producers
(including detached TUI workflow process groups recorded in the run-scoped
lifecycle log) stop before the locked final verification or failure evidence snapshot.
Harness-owned `BUNDLE_GEMFILE`, `HIVE_HOME`, built-in agent fixture binaries,
`HIVE_BIN`, and `HIVE_INVOKED_BIN` cannot be replaced by scenario or operator
overrides. Each per-scenario `HIVE_HOME` is explicitly created and rehardened
to mode `0700` before its configuration is written, independent of the host or
CI runner umask.

Claude, Codex, Pi, and Grok profiles resolve to `test/fixtures/fake-claude`.
Its `HIVE_FAKE_CLAUDE_READY_FILE` /
`HIVE_FAKE_CLAUDE_RELEASE_FILE` barrier publishes a real PID atomically and
waits on a condition file, allowing cross-process races without fixed sleeps.
`spawn_background` owns a process group, and both explicit `stop_process` and
scenario teardown terminate and reap registered groups.
The copied project pins `claude.mode: headless`; this keeps fake Claude on its
subprocess contract instead of sending it through production interactive-tmux
readiness detection. TUI scenarios still run the real long-lived `hive tui`
inside tmux. The harness creates that tmux server inside
`Bundler.with_unbundled_env`, preventing the parent root bundle's `RUBYOPT` or
`BUNDLE_PATH` from being combined with the sample project's Gemfile.

## Artifacts

Every run writes `report.json`:

- `schema: hive-e2e-report`
- `schema_version: 1`
- run timestamps and summary counts
- one entry per scenario with status, duration, failure step, artifacts path, and repro path. Paths are relative to the run directory (`scenarios/<name>/...`) so agents can resolve them from `report.json` without guessing a second base.

On failure, the harness writes a scenario bundle containing:

- `exception.txt`
- `env-snapshot.json` (schema `hive-e2e-env-snapshot`, schema_version 1)
- `sandbox-git-status.txt`
- `sandbox-tree.txt`
- copied `.hive-state/stages/` and per-`.log` copies under `logs/<slug>/<basename>.log` plus a sibling `<basename>.tail` (last 200 lines) for fast agent reads
- `repro.sh`
- `gh/script.json`, `gh/state.json`, and `gh/audit.jsonl` when GitHub scripting was installed or rejected
- `manifest.json` with size and SHA-256 per artifact
- TUI failures also include keystroke captures, run-scoped TUI subprocess marker/capture logs under `tui-subprocess/` (including the current shared marker log and its single `.log.1` rotation), plus `pane-before.txt` (snapshot taken just before the most recent `tui_keys`) and `pane-after.txt`. Cast recording is implemented by `AsciinemaDriver`, but depends on local `asciinema >= 2.4`.

## Current Scenarios

| Scenario | Coverage |
|----------|----------|
| `full_pipeline_happy_path` | Real subprocess choreography from new task to done, avoiding network PR creation. |
| `review_with_findings_then_develop` | `findings --json`, `accept-finding`, schema validation, review file toggles. |
| `run_error_envelope` | `hive run --json` against a stale-locked task emits a parseable `hive-run` error payload. |
| `stale_lock_recovery` | TEMPFAIL lock path, marker clear, rerun recovery. |
| `tui_status_navigate_dispatch_plan` | TUI verb-key dispatch end-to-end: `p` on a ready-to-plan row spawns `bin/hive plan`, waits for the subprocess to exit, and asserts plan.md/COMPLETE landed. |
| `tui_new_idea_editing` | TUI new-idea prompt paste delivery plus cursor navigation/insertion before submit. |
| `tui_two_pane_navigate` | TUI v2 navigation between task list and detail panes, including focus changes and row movement. |
| `two_projects_fuzzy_filter` | tmux TUI filter input and project scope across two registered projects. |
| `update_flow_pipeline` | Daemon update-check pipeline against a releases stub. |
| `update_flow_tui_footer` | TUI update footer rendering after the update check records a newer release. |
| `update_flow_tui_no_nudge` | TUI no-update-nudge path when update state should not be shown. |
| `update_flow_up_to_date` | Daemon update-check path when the installed version is already current. |
| `incident_plan_only_dependency_gate` | Rejects a plan-only assertion, holds exact metadata below the gate, then proves one real dispatch after the prerequisite reaches `8-finalize`. |
| `incident_repository_routing` | Rejects a cross-project dependency whose registered repository identity disagrees with its live origin and preserves the non-target task. |

The six incident-regression fixtures and their current pending/green states
are indexed in `test/e2e/scenarios/README.md`. The two #9771 fixtures are green;
pending fixtures for #9767, #9768, #9769, and #9770 remain report-visible until
their sibling-owned persistence and reason contracts are available.

## Operational Notes

The harness prepends repo `bin/` to the tmux environment PATH because TUI rows dispatch commands like `hive plan ...`. `tui_keys` with `text:` sends literal text one character at a time by default for deterministic slow typing; `paste: true` sends the full `text:` value as one literal tmux chunk to exercise the TUI paste-aware runner.
`CliDriver` starts CLI subprocesses in their own process group and applies the step timeout to both the direct child and stdout/stderr reader threads, so descendants that inherit the capture pipes cannot hold an e2e step open after their parent exits.

Routine pull-request CI runs `e2e:lib_test` and `rake e2e` in a separate job,
retains the run directory even after failure, and feeds that functional job
into the protected `rake test (Ruby 3.4)` aggregate. A downstream advisory job
downloads the artifact and reads enabled incident durations from `report.json`.
Durations include sandbox bootstrap; each enabled incident targets below ten
seconds and the group targets below thirty seconds. Timing failures remain
visible without blocking a merge. Missing enabled results, duplicate
metadata/results, and invalid durations remain functional failures in the E2E
job. Neither job folds e2e into the local default `rake test` task.

`tmux` is required for TUI scenarios. `asciinema` is test-time optional: when
it is unavailable or too old, TUI scenarios run without cast capture while the
other failure artifacts are still recorded. A corrupt produced cast is reported
in the artifact bundle instead of crashing unrelated CLI scenarios. If
`asciinema` is installed outside PATH, set
`HIVE_ASCIINEMA_BIN=/absolute/path/to/asciinema`.

## Backlinks

- [[testing]]
- [[dependencies]]
- [[commands/tui]]
- [[decisions]]
