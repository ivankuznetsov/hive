---
title: Hive::Metrics
type: module
source: lib/hive/metrics.rb
created: 2026-04-26
updated: 2026-04-26
tags: [metrics, rollback, trailers, observability]
---

**TLDR**: Computes the rollback-rate metric for hive fix-agent commits (`hive metrics rollback-rate`). Walks `git log --all` for commits trailered with `Hive-Fix-Pass`, counts how many were later reverted (subject-quote match or `This reverts commit <sha>` body cite), and breaks down by `Hive-Triage-Bias` and `Hive-Fix-Phase`. Trailer parsing is in-process (one regex over each commit body) — no `git interpret-trailers` subprocess per commit. References U14 / ADR-020.

## Public API

```ruby
Hive::Metrics.rollback_rate(project_root, since: nil)
# Returns:
# {
#   "project_root"      => <abs path>,
#   "since"             => <since arg>,
#   "total_fix_commits" => N,
#   "reverted_commits"  => M,
#   "rollback_rate"     => M/N (Float, 0.0 when N == 0),
#   "by_bias"  => { "courageous" => {"total" => …, "reverted" => …, "rate" => …}, … },
#   "by_phase" => { "ci" => {…}, "fix" => {…} }
# }
```

Keys are strings — the JSON emission contract is the canonical shape, and the library API matches it directly so two consumers of the same module can't drift on key style. (Closes ce-code-review AC-3.)

## Trailer schema

Fix-agent commits emit the following trailers (see `templates/fix_prompt.md.erb` and `templates/ci_fix_prompt.md.erb`):

| Trailer | Carried by | Notes |
|---------|-----------|-------|
| `Hive-Task-Slug` | both | Task slug (folder basename). |
| `Hive-Fix-Pass` | both | `01` … `NN` zero-padded. The presence of this trailer is what marks a commit as a "fix-agent commit." |
| `Hive-Fix-Findings` | review-fix only | Count of `[x]` items applied in this commit. |
| `Hive-Triage-Bias` | review-fix only | `courageous` / `safetyist` / custom. |
| `Hive-Reviewer-Sources` | review-fix only | Comma-separated reviewer-file basenames (no NN). |
| `Hive-Fix-Phase` | both | `ci` (Phase 1) or `fix` (Phase 4). |

The canonical list lives in `lib/hive/trailers.rb` (`Hive::Trailers::KNOWN`) and is the documentation source of truth. Templates emit title-case (`Hive-Foo-Bar`); `parse_trailers` canonicalises via `downcase` before lookup. `Hive::Trailers::SCHEMA_VERSION = 1` — bump for breaking changes.

## Helpers (module-level)

| Function | Purpose |
|----------|---------|
| `parse_commits(raw)` | Splits `git log` output (NUL-separated `<sha>\0<subject>\0<body>\0\x01\n` records) into `{sha:, subject:, body:, trailers:}` Hashes. |
| `parse_trailers(body)` | Regex `^([A-Za-z][A-Za-z0-9-]*):\s*(.+)$` → `{"hive-foo" => "bar", …}` (downcased keys). |
| `collect_revert_subjects(commits)` | Hash of `{quoted_subject => [revert_sha, …]}` from `Revert "..."` commits. |
| `collect_revert_shas(commits)` | Hash of `{cited_sha_or_prefix => [revert_sha, …]}` from `This reverts commit <sha>` body cites. |
| `reverted?(commit, revert_subjects, revert_shas)` | True if the fix commit's subject was Revert-quoted, or its sha starts-with any cited prefix in `revert_shas`. |
| `rate_of(bucket)` | `bucket["reverted"].to_f / bucket["total"]` rounded to 4 places. |

## Revert detection

Two equally-valid forms count as a revert:

1. A later commit's subject is `Revert "<exact subject>"`.
2. A later commit's body contains `This reverts commit <sha-or-7+char-prefix>` and the prefix is a real prefix of the fix commit's full sha (no symmetric-prefix collision — closes ce-code-review R4).

`git log --all` is the simplest correct domain for v1; a stray Revert on a different branch shows up as a rollback (conservative direction — biases the user toward `safetyist`).

## Used by

- `Hive::Commands::Metrics` — surfaces text + JSON output.
- `templates/fix_prompt.md.erb` / `templates/ci_fix_prompt.md.erb` — emit trailers (one direction).
- `lib/hive/stages/review.rb` — passes `triage_bias_for` / `reviewer_sources_for` into the fix prompt bindings so trailers land on every fix commit.

## Tests

- `test/unit/metrics_test.rb` — trailer parsing, subject/sha revert detection, since filter, bias buckets, phase split, prefix-collision negative.
- `test/integration/metrics_command_test.rb` — JSON schema, text output, error envelopes.

## Backlinks

- [[stages/review]] · [[cli]] · [[commands/status]]
- [[decisions]] (U14 / ADR-020)
