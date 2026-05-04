---
title: Agentic E2E Suite
type: reference
source: test/e2e/, bin/hive-e2e, Rakefile
created: 2026-04-29
updated: 2026-04-29
tags: [test, e2e, tui, artifacts]
---

**TLDR**: `test/e2e/` is the outer test layer. It drives the real `bin/hive` binary in a copied Ruby sample project, uses tmux for TUI scenarios, validates JSON output against published schemas, and writes versioned run artifacts for later debugging.

## Commands

```bash
bundle exec rake e2e:lib_test   # harness library tests
bin/hive-e2e list               # scenario inventory
bin/hive-e2e run                # all scenarios
bin/hive-e2e run --filter tui   # tag filter
bin/hive-e2e clean              # old run cleanup
```

`rake e2e` delegates to `bin/hive-e2e run`. The default `rake test` suite does not run e2e scenarios.

## Layout

| Path | Purpose |
|------|---------|
| `test/e2e/lib/` | Harness library: sandbox bootstrap, CLI driver, tmux driver, parser, executor, artifact capture, report writer. |
| `test/e2e/scenarios/*.yml` | Agent-authorable scenarios using the locked YAML vocabulary. |
| `test/e2e/sample-project/` | Tiny Ruby fixture copied into each scenario sandbox. Vendored gems keep bootstrap offline. |
| `test/e2e/runs/` | Gitignored run artifacts. Each run has `report.json` and per-scenario artifact directories. |
| `bin/hive-e2e` | Thor shell for run/list/replay/clean. |

## Scenario DSL

Supported step kinds:

- `cli`: run the real `bin/hive` subprocess with `args`, `expect_exit`, optional `env`, `cwd`, and timeout.
- `json_assert`: run a CLI command, parse stdout, validate it against a `schemas/hive-*.json` file, then optionally assert a `pick` path.
- `state_assert`: assert file existence, absence, marker state, substring, or regex match; supports a short timeout for async TUI updates.
- `seed_state`, `write_file`, `register_project`, `ruby_block`: fixture setup escape hatches.
- `tui_expect`, `tui_keys`, `wait_subprocess`: tmux-backed TUI interaction.
- `editor_action`, `log_assert`: narrower fixture helpers for editor/log flows.

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
- `manifest.json` with size and SHA-256 per artifact
- TUI failures also include keystroke captures, run-scoped TUI subprocess marker/capture logs under `tui-subprocess/`, plus `pane-before.txt` (snapshot taken just before the most recent `tui_keys`) and `pane-after.txt`. Cast recording is implemented by `AsciinemaDriver`, but depends on local `asciinema >= 2.4`.

## Current Scenarios

| Scenario | Coverage |
|----------|----------|
| `full_pipeline_happy_path` | Real subprocess choreography from new task to done, avoiding network PR creation. |
| `review_with_findings_then_develop` | `findings --json`, `accept-finding`, schema validation, review file toggles. |
| `run_error_envelope` | `hive run --json` against a stale-locked task emits a parseable `hive-run` error payload. |
| `stale_lock_recovery` | TEMPFAIL lock path, marker clear, rerun recovery. |
| `tui_status_navigate_dispatch_plan` | TUI verb-key dispatch end-to-end: `p` on a ready-to-plan row spawns `bin/hive plan`, waits for the subprocess to exit, and asserts plan.md/COMPLETE landed. |
| `tui_new_idea_editing` | TUI new-idea prompt paste delivery plus cursor navigation/insertion before submit. |
| `two_projects_fuzzy_filter` | tmux TUI filter input and project scope across two registered projects. |

## Operational Notes

The harness prepends repo `bin/` to the tmux environment PATH because TUI rows dispatch commands like `hive plan ...`. `tui_keys` with `text:` sends literal text one character at a time by default for deterministic slow typing; `paste: true` sends the full `text:` value as one literal tmux chunk to exercise the TUI paste-aware runner.

`tmux` is required for TUI scenarios. `asciinema` is test-time optional until a TUI failure needs a cast, but missing/corrupt casts are recorded in artifacts instead of crashing unrelated CLI scenarios. If `asciinema` is installed outside PATH, set `HIVE_ASCIINEMA_BIN=/absolute/path/to/asciinema`.

## Backlinks

- [[testing]]
- [[dependencies]]
- [[commands/tui]]
- [[decisions]]
