---
title: hive metrics
type: command
source: lib/hive/commands/metrics.rb, lib/hive/metrics.rb
created: 2026-05-21
updated: 2026-09-02
tags: [command, metrics, review, rollback]
---

**TLDR**: `hive metrics rollback-rate` reports how often Hive fix-agent commits are later reverted, optionally scoped by project and time window.

## Usage

```bash
hive metrics rollback-rate [--days N] [--project NAME] [--json]
```

`rollback-rate` is the default subcommand, so `hive metrics` currently runs the same report.

## Inputs

The command reads registered projects from global config and walks each project git history. `--project NAME` matches the registry entry's `name`. `--days N` must be a positive integer and maps to `git log --since="N days ago"`.

Fix-agent commits are identified by trailers written by review fix prompts:

- `Hive-Fix-Pass`
- `Hive-Triage-Bias`
- `Hive-Fix-Phase`

`Hive::Metrics.rollback_rate` then detects later reverts and groups totals by triage bias and fix phase.

## Output

Text output prints one section per project with total fix commits, reverted count, percentage, and grouped buckets.

`--json` emits schema `hive-metrics-rollback-rate` with `schema_version`, `since`, and `projects[]` entries containing:

- `project`
- `project_root`
- `total_fix_commits`
- `reverted_commits`
- `rollback_rate`
- `by_bias`
- `by_phase`

Usage failures, including missing or extra arguments rejected before command
dispatch, emit a JSON error envelope with a closed `error_kind` such as
`invalid_days`, `unknown_project`, `unknown_subcommand`, or
`no_projects_registered`.
The command uses the shared `Hive::Schemas::EnvelopeEmitter` rescue and
single-document guard, but overrides its payload builder to preserve the
published metrics v1 allowlist. Metrics error payloads intentionally omit
`error_class`. If error-envelope encoding raises `JSON::GeneratorError`,
metrics suppresses that serialization failure, emits no fallback document,
and re-raises the original typed command error so it still controls the exit
boundary.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | The requested rollback-rate report was emitted. |
| 64 | Days, project, subcommand, or argument shape was invalid. |
| 70 | An unexpected producer failure was wrapped as an internal error. |
| 78 | The global or project configuration was invalid. |

## Tests

- `test/unit/metrics_test.rb` covers trailer parsing, revert detection, and grouping.
- `test/integration/metrics_command_test.rb` covers CLI text/JSON behavior and typed usage errors.

## Backlinks

- [[cli]] · [[stages/review]] · [[modules/reviewers]]
