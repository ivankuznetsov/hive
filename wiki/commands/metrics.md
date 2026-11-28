---
title: hive metrics
type: command
source: lib/hive/commands/metrics.rb, lib/hive/metrics.rb
created: 2026-05-21
updated: 2026-09-02
tags: [command, metrics, review, rollback]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-metrics) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive metrics rollback-rate` reports how often Hive fix-agent commits are later reverted, optionally scoped by project and time window.

## Inputs and implementation

The command reads registered projects from global config and walks each project git history. `--project NAME` matches the registry entry's `name`. `--days N` must be a positive integer and maps to `git log --since="N days ago"`.

Fix-agent commits are identified by trailers written by review fix prompts:

- `Hive-Fix-Pass`
- `Hive-Triage-Bias`
- `Hive-Fix-Phase`

`Hive::Metrics.rollback_rate` detects later reverts and groups totals by triage bias and fix phase. `Hive::Commands::Metrics` uses `Hive::Schemas::EnvelopeEmitter`'s rescue and single-document guard while overriding its payload builder to preserve the v1 metrics error allowlist.

## Tests

- `test/unit/metrics_test.rb` covers trailer parsing, revert detection, and grouping.
- `test/integration/metrics_command_test.rb` covers CLI text/JSON behavior and typed usage errors.

## Backlinks

- [[cli]] · [[stages/review]] · [[modules/reviewers]]
