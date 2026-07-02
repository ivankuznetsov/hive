---
title: hive digest
type: command
source: lib/hive/cli.rb, lib/hive/commands/digest.rb, lib/hive/digest.rb, lib/hive/digest/
created: 2026-06-14
updated: 2026-06-30
tags: [command, digest, telegram, json]
---

**TLDR**: `hive digest [--date YYYY-MM-DD] [--dry-run] [--json]`
builds the daily shipped digest for completed `9-done` tasks across
registered projects. The pipeline collects tasks shipped on one local
calendar date, asks an agent to classify and summarize them when there is
work to report, renders Telegram MarkdownV2, and sends through the bot
Telegram client. `hive digest --source merged-prs` switches to a read-only
GitHub merged-PR report for the same local date; that source is mechanical
and does not invoke the digest agent. Runtime config is loaded through
`Hive::Config.load_global_digest_config`, so real sends can use
`digest.agent`, `budget_usd.digest`, `timeout_sec.digest`, and
`bot.chat_id_allowlist`. See [[modules/digest]].

## Synopsis

```bash
hive digest [--date YYYY-MM-DD] [--dry-run] [--json]
hive digest --source merged-prs [--date YYYY-MM-DD] [--repo owner/name ...] [--dry-run] [--json]
```

Options:

| Option | Behavior |
|--------|----------|
| `--date YYYY-MM-DD` | Digest this local calendar date. Invalid formats raise `Hive::ConfigError`. |
| omitted `--date` | Uses the local calendar day that just ended via `Hive::Digest::Window.previous_local_day`. |
| `--dry-run` | Avoids Telegram auth/chat lookup and prints the composed message. |
| `--json` | Emits a small versioned JSON delivery document instead of prose. |
| `--source merged-prs` | Reports GitHub PRs merged on the local date instead of shipped Hive tasks. |
| `--repo owner/name` | Restricts the merged-PR source to explicit repositories. Repeatable; implies `--source merged-prs`. |

## Behavior

Default source:

1. `Hive::Commands::Digest#parse_date` accepts only `YYYY-MM-DD`; omitted
   dates default to yesterday in the host local timezone.
2. `Hive::Digest.run` asks `Digest::Collector` for shipped items on that date.
   The collector scans every registered project's `.hive-state/stages/9-done/*`
   folders, reads `meta.yml`, reads `pr.md` frontmatter/body, and uses
   `Digest::ShipTimes` to find the ship timestamp from `hive/state` git log
   subjects. Ship time preference is `pr_finalized`, then `archived`, then an
   older `approve -> 9-done` commit shape.
3. If no items shipped, `Digest::Renderer.empty` returns the "Nothing shipped
   today" message and no agent is spawned.
4. If items shipped, `Digest::Categorizer` renders `templates/digest_prompt.md.erb`,
   spawns the resolved `AgentProfile` with `status_mode: :output_file_exists`,
   requires an `items.json` output (`{"summary": "...", "items": [...]}`), then
   maps rows back by the project-scoped categorizer id (`<project_name>/<pr_number>`,
   or `<project_name>/<slug>` when there is no PR number) so two projects sharing
   a PR number on one day don't collide. Allowed categories are `feature`, `fix`,
   and `patrol`; missing/invalid/duplicate-id rows log a warning and default to
   `feature` with a fallback summary. The model's top-level `summary` (one
   sentence about the day) is surfaced too, falling back to a neutral count when
   omitted. `categorize` returns a `Digest::Output(by_project:, summary:)`.
5. `Digest::Stats` fetches per-PR additions/deletions/commits via
   `Hive::Gh.pr_stats(pr_url)` (keyed off the PR URL, no worktree needed) and
   aggregates global `Totals(prs:, commits:, additions:, deletions:, measured_prs:)`.
   A per-PR `gh` failure is logged and skipped — the digest never fails for want
   of footer numbers.
6. `Digest::Renderer` renders the brand header `*Hive* #Digest` + a human date
   (`Fri, 19 June 2026`), an italic `_Summary_` block, then **per-project**
   sections (`*Hive*`, `*Screenote*`, …) each with categories in fixed order
   (`Features`, `Fixes`, `Patrol`), and a global footer under a divider
   (`Lines +A/-D · PRs P · Commits C`; Lines/Commits appear only when at least
   one PR's stats were measured). All dynamic text is MarkdownV2-escaped and
   links to PR URLs when present.
7. `Digest::Sender` sends the message with `parse_mode: :markdown_v2` (one
   `send_message` per chunk above Telegram's 4096-char limit), or returns the
   text without credentials in dry-run mode.

If pending Telegram pairing requests exist, `Hive::Digest.run` appends one
reminder line to the empty or successful digest body: `🔑 N pairing request(s)
waiting — run hive pairing list`. The count comes from the local
`PairingStore`, not from the categorizer prompt.

If categorization raises `Hive::Digest::ModelError`, `Hive::Digest.run` sends
a failed-generation notice for the date and returns `status: :failed_notice`.

## Merged-PR Source

`hive digest --source merged-prs` reports pull requests merged on one local
calendar date. It is a read-only GitHub reporting source: it calls `gh`, reads
registered Hive project state for optional task annotation, never mutates Hive
state, and never runs the paid digest agent.

Repository selection:

- Without `--repo`, Hive scans `Hive::Config.registered_projects` and resolves
  each project path with `gh repo view --json nameWithOwner`.
- A project that cannot be resolved is warned and dropped; other repos still
  report.
- `--repo owner/name` bypasses discovery, validates the slug shape, de-dupes
  repeats, and can be repeated.

Collection:

- The command asks GitHub for merged PR candidates with
  `gh pr list --repo owner/name --state merged --search merged:<D-1>..<D+1>`
  and final membership is `mergedAt.getlocal.to_date == D`.
- Open, closed-unmerged, and draft-but-not-merged PRs are excluded by GitHub's
  merged state. Bot authors, non-Hive PRs, and fork PRs are included; bot/fork
  metadata is carried in JSON.
- A per-repo `gh` failure is warned and dropped while the digest still
  succeeds with a partial result.
- Branches named `hive/<slug>` are best-effort matched against registered
  projects' `.hive-state/stages/*/<slug>` directories to fill optional
  `hive_slug` / `hive_stage`. Match failures are swallowed.

Rendering is mechanical and grouped by repo:

```text
Merged PR digest — 2026-06-13

Total: 2 PRs

`owner/repo — 2`
• #12 Add export — alice
• #13 Fix docs — Hive task matched
```

Dry-run prints the message and sends nothing. A real run sends through the
same `Digest::Sender` / Telegram MarkdownV2 path as the shipped-task digest.

## Output

Human output:

- Dry-run: prints the composed message body.
- Real send: prints `hive digest: <status> for <date>`.

For the default shipped-task source, `--json` prints a delivery document for empty/sent/failed_notice: a model
failure still prints this shape with `ok: false` and `status:
"failed_notice"`.

```json
{
  "ok": true,
  "schema": "hive-digest",
  "schema_version": 1,
  "date": "2026-06-13",
  "status": "sent",
  "dry_run": true,
  "chat_id": 12345,
  "message": "..."
}
```

`message` is included only for dry-run output; real-send JSON sets it to
`null`. `chat_id` is the recipient the send resolved (`null` on a dry-run);
it is an optional field, so older consumers that ignore it stay compatible.
`hive-digest` is registered in `Hive::Schemas::SCHEMA_VERSIONS` (v1) and
published under `schemas/hive-digest.v1.json`.

The merged-PR source emits `hive-merged-pr-digest` v1:

```json
{
  "ok": true,
  "schema": "hive-merged-pr-digest",
  "schema_version": 1,
  "date": "2026-06-13",
  "source": "merged-prs",
  "dry_run": true,
  "repos": ["owner/repo"],
  "count": 1,
  "prs": [
    {
      "repo": "owner/repo",
      "number": 12,
      "title": "Add export",
      "url": "https://github.com/owner/repo/pull/12",
      "mergedAt": "2026-06-13T12:00:00Z",
      "author": "alice",
      "authorIsBot": false,
      "headRefName": "hive/add-export-260613-abcd",
      "isCrossRepository": false,
      "hive_slug": "add-export-260613-abcd",
      "hive_stage": "9-done"
    }
  ],
  "message": "...",
  "chat_id": null
}
```

Real-send JSON sets `message` to `null` and `chat_id` to the resolved
recipient. Partial repo drops still return `ok: true`; only command-level
errors use the ErrorPayload arm.

Usage errors emit the shared `ErrorPayload` (same `hive-digest` schema):

- a bad `--date` raises `Hive::ConfigError` and the command emits the
  envelope itself (`error_kind: "config"`, exit 78) before re-raising;
- a malformed invocation caught before dispatch (unknown flag / malformed
  `--json`) emits via `JSON_USAGE_ERROR_CONTRACTS` (`error_kind: "usage"`,
  exit 64).

A Telegram send error that occurs mid-delivery still stays on the stderr +
non-zero exit-code path without an envelope.

Exit codes: `0` empty/sent/failed_notice (a notice was delivered); `78` bad
`--date` or missing chat config; `64` bad flags / malformed `--json`; `70`
unexpected internal error.

## Config And Auth

`Hive::Digest.run` defaults to `Hive::Config.load_global_digest_config` and
the direct API can still override that with `cfg:`. Supported keys:

- `digest.agent` — preferred summarizer agent.
- `patrol.agent` — fallback summarizer agent.
- `budget_usd.digest` — categorizer budget override; default is `50`.
- `timeout_sec.digest` — categorizer timeout override; default is `1800`.
- `bot.chat_id_allowlist[0]` — Telegram chat id the digest is delivered to.
- `bot.log_file` — Telegram client log path fallback.

`Digest::Sender` always gets the bot token from
`Hive::Config.telegram_bot_token!`, so the token source is still
`HIVE_TELEGRAM_BOT_TOKEN`.

For a **real** send (not `--dry-run`), `Hive::Digest.run` first calls
`Hive::EnvFile.load!`, loading `~/.config/hive/.env` so the token is available
even when the surrounding environment does not export it. This matters most
for the daemon: the `DigestScheduler` dispatches `hive digest --date <day>
--json` from a systemd/detached process whose environment has **no**
`HIVE_TELEGRAM_BOT_TOKEN`, and only `hive bot start` used to load the `.env`
(see [[commands/bot]]). Before this, every daemon-scheduled digest failed
`Sender#preflight!` with exit 78 and the scheduler hot-looped on its failure
backoff. An exported env var still wins over the file, and a dry-run never
loads it (it never sends). See [[modules/digest]] and [[modules/config]].

The daemon schedules the command through `Hive::Daemon::DigestScheduler` when
`digest.enabled` is on, dispatching `hive digest --date <day> --json` once per
owed local day. The digest is **opt-out**: when the operator has not set
`digest.enabled` either way, `Hive::Config.load_global_digest_block` derives it
from the bot config — it auto-enables (`true`) when the Telegram bot is
configured with an allowlisted chat (`bot.enabled == true` and
`bot.chat_id_allowlist` has at least one integer chat id), and is `false`
otherwise. An explicit `digest.enabled: false` is the opt-out (and an explicit
`digest.enabled: true` is always honored). See [[modules/config]] and
[[commands/daemon]].

## Tests

- `test/unit/cli_test.rb` covers Thor option threading for `hive digest`.
- `test/unit/commands/digest_test.rb` covers dry-run output, success JSON, and
  date validation, plus merged-PR dispatch and envelope validation.
- `test/unit/digest/merged_pr/*_test.rb` covers repo resolution, collection
  boundaries, Hive matching, rendering, and runner orchestration.
- `test/unit/digest/run_test.rb` covers empty, successful, failed-notice, and
  default-date pipeline behavior through injected seams.
- `test/unit/digest/sender_test.rb` covers chat-id resolution, dry-run token
  avoidance, and MarkdownV2 Telegram send arguments.
- `test/unit/daemon/digest_scheduler_test.rb` covers daemon due/catch-up
  behavior.
- `test/digest/e2e_test.rb` is an opt-in live agent + Telegram test.

## Backlinks

- [[cli]]
- [[commands]]
- [[modules/digest]]
- [[modules/config]]
- [[commands/bot]]
