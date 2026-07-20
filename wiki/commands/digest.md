---
title: hive digest
type: command
source: lib/hive/commands/digest.rb, lib/hive/digest.rb, lib/hive/digest/, templates/digest_prompt.md.erb
created: 2026-06-14
updated: 2026-07-20
tags: [command, digest, github, telegram, json]
---

**TLDR**: `hive digest` builds one complete daily changelist from pull requests
merged during a Europe/London calendar day across registered GitHub
repositories. Hive tasks, stage folders, completion state, and pairing state
do not affect inclusion. The only live JSON identity is `hive-digest` v2.

## Synopsis

```bash
hive digest [--date YYYY-MM-DD] [--repo owner/name ...] [--dry-run] [--json]
```

Examples:

```bash
hive digest --dry-run
hive digest --date 2026-07-19 --dry-run --json
hive digest --repo ivankuznetsov/hive --repo owner/other --dry-run
hive digest --date 2026-07-19 --json
```

| Option | Meaning |
|---|---|
| `--date YYYY-MM-DD` | Europe/London day to report. Defaults to the previous completed London day. |
| `--repo owner/name` | Case-insensitive filter over repositories resolved from registered projects. Repeatable; an invalid, unknown, or empty filter fails. It cannot add an unregistered repository. |
| `--dry-run` | Render the exact Telegram MarkdownV2 changelist to stdout without loading Telegram credentials or sending. |
| `--json` | Emit the `hive-digest` v2 success or error envelope. On a dry-run, `message` contains the rendered text; on a real send it is `null`. |

The removed `--source` option is an error. There is no shipped-task mode and
no compatibility selector.

## Selection And Collection

The resolver reads registered project paths, parses each Git origin into its
canonical GitHub `owner/name` and host, de-duplicates targets, and then applies
`--repo`. A discovery failure becomes a repository warning when another target
survives. Zero resolved targets fails before collection or delivery.

For each resolved target, the collector:

1. Lists closed pull requests through exhaustively paginated, explicit-host
   GitHub REST calls ordered by `updated_at`.
2. Selects rows whose `merged_at` falls inside the requested London day. UTC
   bounds come from `tzinfo`, including 23-hour and 25-hour DST transition days.
3. Fetches canonical repository metadata, each qualifying PR detail/body, its
   raw GitHub diff, and every paginated file identity.
4. Cross-checks repository, PR, merge-time, changed-file count and names, and
   rejects missing or malformed required evidence atomically for that
   repository.

A successful zero-PR query is a successful repository. If every repository
fails required collection, the command exits nonzero and sends nothing. If
some fail, the digest includes the complete successful repositories and
repository-scoped warnings. It never drops an individual qualifying PR and
falls back to its title.

Raw body and diff evidence is written only to owner-only ephemeral scratch
files. The collector enforces fixed 64 MiB per-PR, 256 MiB per-repository, and
512 MiB per-digest safety ceilings. Crossing a ceiling fails the affected
repository. Recognized secrets are replaced with typed placeholders before
agent-provider egress; raw files are removed after the redacted checksum is
verified and are not retained as diagnostics.

## Changelist Generation

Nonempty input is sent to one configured digest agent invocation. The manifest
assigns stable IDs to body sections and diff hunks/file markers. The agent must
first produce a fact ledger covering every evidence ID exactly once, then one
significance sentence per project and one or more concrete bullets per PR.
Every material fact must be cited by a bullet for the same PR.

Hive validates exact evidence, fact, project, and PR identity sets. Missing,
duplicate, unknown, blank, title-only, zero-bullet, or uncovered output is a
generation failure: the command exits nonzero and sends nothing. An honestly
collected empty day skips the agent entirely and still renders/delivers the
normal digest with `PRs 0`.

Generated significance and bullet text is scanned and redacted again before
the result leaves the agent boundary. Retained generation diagnostics contain
only redacted evidence/fact/bullet ledgers and checksums, never the raw prompt,
body, diff, or recognized credential value.

## Human Output And Statistics

The renderer owns deterministic project/PR order, counts, PR numbers, links,
warnings, and MarkdownV2 escaping. Each project starts with its significance
sentence and PR count/statistics, followed by every PR title/link and every
generated change bullet. The message ends with the established divider and
compact middle-dot footer, for example:

```text
──────────
Lines +42/-7 · PRs 2 · Commits 3
```

Additions, deletions, and commit counts are optional independently per PR.
Known values, including a measured zero, remain in JSON. Project and overall
totals sum only known values. A subtotal with some missing contributors is
labelled `(partial)` and accompanied by a repository/PR/metric warning; a
metric with no known contributing values is omitted. An empty day reports
`PRs 0` and does not invent line or commit totals.

Long output is split at safe raw-text boundaries before Telegram MarkdownV2
delivery. A mid-stream send failure is nonzero and logs accepted/failed chunk
positions without claiming success. A later daemon retry re-sends the whole
date, so a rare failure after earlier chunks were accepted can duplicate those
chunks.

## JSON Contract

`hive digest --json` emits only `hive-digest` v2. A nonempty dry-run resembles:

```json
{
  "schema": "hive-digest",
  "schema_version": 2,
  "ok": true,
  "date": "2026-07-19",
  "status": "sent",
  "dry_run": true,
  "resolved_repository_count": 2,
  "collected_repository_count": 1,
  "project_count": 1,
  "pr_count": 1,
  "additions": 42,
  "projects": [
    {
      "repository": "owner/repo",
      "description": "These changes make daily reporting reliable.",
      "pr_count": 1,
      "additions": 42,
      "prs": [
        {
          "number": 17,
          "url": "https://github.com/owner/repo/pull/17",
          "title": "Unify digest collection",
          "merged_at": "2026-07-19T12:00:00Z",
          "additions": 42,
          "bullets": ["Collects complete PR body and diff evidence."]
        }
      ]
    }
  ],
  "warnings": [
    {
      "kind": "statistics_incomplete",
      "repository": "owner/repo",
      "pr_number": 17,
      "metrics": ["deletions", "commits"],
      "message": "Statistics unavailable for owner/repo#17: deletions, commits"
    }
  ],
  "chat_id": null,
  "message": "..."
}
```

Unknown per-PR metrics and totals are absent, never `null` or zero. Real sends
set `message` to `null` and carry the resolved `chat_id`. Error envelopes keep
the same schema/version with `ok: false`, `error_class`, `error_kind`,
`exit_code`, and `message`. Invalid dates and repository filters use
`error_kind: config`; wrapper usage errors use `usage`; collection/generation
failures use `internal`. A failed command sends no successful changelist.

The published schema is `schemas/hive-digest.v2.json`.
`schemas/hive-digest.v1.json` remains immutable historical documentation.

## Migration From Earlier Digests

- Remove `--source shipped` and `--source merged-prs`; bare `hive digest` is
  now the PR-only command.
- Remove `digest.source` from configuration.
- Treat `--repo` as a filter over registered repositories, not a way to query
  arbitrary repositories.
- Migrate both `hive-digest` v1 and `hive-merged-pr-digest` v1 consumers to
  `hive-digest` v2. There is no live alias for the merged identity.
- Replace shipped-task status/category/summary assumptions with
  `projects[].description`, `projects[].prs[].bullets`, repository counts,
  optional measured metrics, and structured `warnings`.
- Remove consumers of Hive match fields such as `hive_slug` and `hive_stage`.
  Task completion and `9-done` no longer affect digest inclusion.

## Config, Auth, And Scheduling

Generation uses `digest.agent`, falling back to `patrol.agent` and then
`claude`, plus `budget_usd.digest` (default `50`) and `timeout_sec.digest`
(default `1800`). Real delivery loads `~/.config/hive/.env`, resolves
`bot.chat_id_allowlist[0]`, and requires `HIVE_TELEGRAM_BOT_TOKEN` before the
paid generator starts. Dry-run remains credential-free.

When enabled, `Hive::Daemon::DigestScheduler` runs exactly:

```bash
hive digest --date YYYY-MM-DD --json
```

It seeds without historical backfill on first run, catches up oldest-first,
honours `digest.max_catchup_days`, advances its cursor after empty or
warning-bearing success, and leaves a total collection or generation failure
owed with 60/300/900-second backoff. Day calculations use Europe/London;
`hive answer-digest` retains its separate host-local schedule.

PR bodies/diffs cross the configured agent-provider boundary only after
recognized-secret redaction. Generated changelist text crosses the Telegram
boundary on real sends. Operators should account for both outbound boundaries
when choosing providers and recipients.

## Tests

- `test/unit/digest/{london_window,repo_resolver,collector,stats}_test.rb`
  covers target scope, DST, complete GitHub evidence, failure outcomes,
  redaction, safety ceilings, and optional metrics.
- `test/unit/digest/changelog_generator_test.rb` covers strict
  evidence-to-fact-to-bullet generation.
- `test/unit/digest/{run,renderer,sender}_test.rb` and
  `test/unit/bot/telegram_test.rb` cover orchestration, human output, safe
  splitting, and delivery failure.
- `test/unit/commands/digest_test.rb`, schema tests, and CLI integration tests
  cover the sole v2 producer and error envelopes.
- `test/unit/daemon/digest_scheduler_test.rb` covers the cursor, catch-up,
  backoff, and London dates.

## Backlinks

- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[modules/digest]]
- [[modules/config]]
- [[modules/gh]]
