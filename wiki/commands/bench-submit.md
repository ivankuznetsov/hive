---
title: hive bench submit
type: command
source: lib/hive/commands/bench_submit.rb
tags: [command, bench, corpus]
---

**TLDR**: `hive bench submit SLUG [--project NAME]` extracts a completed
(`9-done`) task into a [hive-bench](https://github.com/ivankuznetsov/hive-bench)
corpus entry and opens a submission PR. A low-friction producer for the
benchmark — it reuses hive-bench's own extractor and runs a local secret/PII
preflight, aborting before any PR if a secret is found.

## Behavior

1. Resolves `SLUG` to a `9-done` task across registered projects (`--project`
   to disambiguate). A missing or ambiguous slug is a USAGE error (64).
2. Verifies the task is extractable (`worktree.yml:execute_base_head`, `pr.md`
   present) — otherwise aborts.
3. Runs a local secret/PII preflight over the task's spec/PR; any finding aborts
   before a PR is opened.
4. Shells to hive-bench's `harness/extract.rb` (located via `HIVE_BENCH_PATH`,
   default `~/Dev/hive-bench`) to build the entry, deriving the source repo from
   the project's `origin` remote.
5. Commits the entry on a `submit-<slug>` branch and opens a PR to
   `ivankuznetsov/hive-bench`, where the validator CI checks reproducibility,
   leakage, secrets, and provenance before merge.

## Notes

- hive depends on hive-bench only as a *producer* here; hive-bench never depends
  on hive. See [[commands]] for the full command list.
- `--json` emits `{schema, slug, entry, pr_url}`.
