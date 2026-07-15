---
title: Hive::Digest
type: module
source: lib/hive/digest.rb, lib/hive/digest/, templates/digest_prompt.md.erb
created: 2026-06-14
updated: 2026-07-15
tags: [digest, merged-pr, shipped, telegram, module]
---

**TLDR**: `Hive::Digest` is the library pipeline behind [[commands/digest]].
`Digest::Source` resolves explicit CLI input, `--repo`, and the validated
`digest.source` setting, defaulting to the read-only `merged-prs` GitHub
report. The shipped-task source remains available through `--source shipped`.
Both sources share the local-date window, best-effort PR stats aggregation,
Telegram MarkdownV2 footer, and sender, while retaining separate collection
and JSON contracts (`hive-merged-pr-digest` and `hive-digest`). Runtime config
is loaded through `Hive::Config.load_global_digest_config`, and orchestration
seams keep collection, stats, rendering, and delivery independently testable.

## API Map

| API | Purpose |
|-----|---------|
| `Digest::Source.resolve(explicit: nil, repos: [], configured: nil)` | Resolves the source with precedence `--source` → presence of `--repo` → `digest.source` → `merged-prs`; validates the only accepted values (`merged-prs`, `shipped`) and rejects explicit `shipped` plus `--repo`. `schema_for` and the options/argv helpers map the same resolved source to its honest v1 JSON envelope. |
| `Hive::Digest.run(date: nil, dry_run: false, cfg: nil, clock: -> { Time.now }, collector: nil, categorizer: nil, sender: nil, stats: nil, pairing_store: Hive::Bot::PairingStore.new)` | Orchestrates collection, categorization, stats, rendering, pairing-request reminder appending, and delivery. Defaults `cfg` via `Config.load_global_digest_config` and `stats` to `Stats.new`. For a real send (not `dry_run`) it first calls `Hive::EnvFile.load!` so `~/.config/hive/.env` supplies `HIVE_TELEGRAM_BOT_TOKEN` even when the environment doesn't export it — this is what lets the daemon-dispatched `hive digest` authenticate (its systemd/detached launch env has no token; previously only `hive bot start` loaded the `.env`). An exported env var still wins; a dry-run never loads it. Returns `Result(status:, date:, message:, delivery:)`. |
| `Digest::Window.local_today`, `previous_local_day`, `on_local_date?`, `parse_date`, `parse_time` | Local-date window helpers. `previous_local_day(now:)` is the shared "yesterday local" default used by both the CLI command and `Digest.run`. Collection compares `shipped_at.getlocal.to_date` to the requested date. |
| `Digest::ShipTimes#shipped_at(hive_state_path:, slug:)` | Reads git log on `hive/state` (fixed-string `-F` grep) and picks the ship commit by **action preference** — `pr_finalized`, else `archived`, else approval into `9-done` — not whichever commit is chronologically first. |
| `Digest::Collector#for_date(date)` | Scans registered projects and builds grouped `ShippedItem` rows from `9-done` task folders, `meta.yml`, `pr.md`, and ship times. |
| `Digest::Categorizer#categorize(grouped, date:)` | Renders the digest prompt and runs an `AgentProfile` expecting an `items.json` file. Returns `Digest::Output(by_project:, summary:)`. |
| `Digest::Categorizer.map_output_file` / `map_document` | Validates and maps model JSON rows back to shipped items (the `{project => [CategorizedItem]}` shape), defaulting bad/missing categories safely. `load_doc!` reads/parses the file; `summary_from` extracts the overall summary with a count fallback. |
| `Digest::Stats#for_items(items)` | Sums per-PR `Hive::Gh.pr_stats(pr_url)` (injectable `fetch:`) into `Totals(prs:, commits:, additions:, deletions:, measured_prs:)`; a per-PR `gh` failure is logged and skipped. |
| `Digest::Renderer.render(by_project, date:, summary:, totals:)`, `.empty`, `.failed`, `.escape_mdv2` | Builds the Telegram MarkdownV2 message: brand header + date, `_Summary_`, per-project sections, and the global stats footer. |
| `Digest::Sender#deliver(text, dry_run:)` | Returns dry-run text or sends the Telegram MarkdownV2 message (chunked into one `send_message` per chunk above Telegram's 4096-char limit). |
| `Digest::MergedPr.run(date: nil, dry_run: false, repos: [], cfg: nil, clock: -> { Time.now }, resolver: nil, collector: nil, sender: nil, stats: nil)` | Orchestrates the merged-PR source: resolve repos, collect PRs merged on the local date, aggregate best-effort stats, render mechanically, and deliver through `Digest::Sender`. Returns `MergedPr::Result`. |
| `Digest::MergedPr::RepoResolver#resolve(repos:)` | Uses explicit `owner/name` repos when supplied, otherwise resolves registered project paths through `Gh.repo_name_with_owner`. Per-project failures are warned and dropped; automatic discovery raises `ConfigError` when no repository survives. |
| `Digest::MergedPr::Collector#for_date(date, repos:)` | Calls `Gh.list_merged_prs` per repo, filters by `Window.on_local_date?(mergedAt, date)`, maps author/bot/fork metadata, and best-effort annotates `hive/<slug>` branches. |
| `Digest::MergedPr::Renderer.render(prs, date:, totals:)` | Mechanical Telegram MarkdownV2 renderer grouped by repo with per-repo counts, PR links, and the shared divider/footer. The known row count is authoritative for `PRs N`; Lines/Commits appear only when at least one PR was measured. |

`Digest::Result#status` is one of:

- `:empty` — no shipped items, empty message delivered or printed.
- `:sent` — non-empty digest rendered and delivered or printed.
- `:failed_notice` — categorizer model failed, so a failure notice was
  delivered or printed.

## Data Flow

```text
registered projects
  -> .hive-state/stages/9-done/* folders
  -> Digest::ShipTimes over git log hive/state
  -> ShippedItem(project, slug, display_name, pr_url, pr_number, pr_title, pr_body, shipped_at)
  -> Digest::Categorizer (agent writes {summary, items} to items.json)
  -> Output(by_project: {project => [CategorizedItem(item, category, summary)]}, summary:)
  -> Digest::Stats.for_items (gh pr view per PR) -> Totals(prs, commits, additions, deletions, measured_prs)
  -> Digest::Renderer.render(by_project, date:, summary:, totals:) (Telegram MarkdownV2)
  -> Digest::Sender (Telegram bot client)
```

The rendered message is: a brand header (`*Hive* #Digest`) + human date, an
italic `_Summary_` block (the model's one-line overview, or a neutral count
fallback), one **per-project** section (`*Hive*`, capitalized) each with
`Features`/`Fixes`/`Patrol` subsections in fixed order, then a global footer
under a divider — `Lines +A/-D · PRs P · Commits C`. Lines/Commits are shown
only when `Totals#measured_prs` is positive, so a `gh`-unavailable run degrades
to just the PR count instead of a misleading `+0/-0`.
When `PairingStore#pending.size` is positive, `Digest.run` appends one final
line shaped as `🔑 N pairing request(s) waiting — run hive pairing list` to both the
empty and successfully-rendered digest paths. This local file read happens
outside the categorizer prompt, so pending pairing requests do not spend agent
budget.

Collection is deliberately tolerant of incomplete task artifacts:

- Missing `meta.yml` falls back to the folder basename for slug/display name.
- Missing `pr.md` leaves PR URL/body blank.
- Malformed PR frontmatter is handled by `Hive::Gh.pr_frontmatter`; the body
  is read via the shared `Hive::Gh.pr_body` helper (one definition of the
  `---…---` frontmatter delimiter) and capped to a generous per-item length so
  one oversized `pr.md` can't blow the categorizer's context/budget.
- `Hive::GitError` — or an unreadable/directory-shaped `pr.md` surfacing as
  `SystemCallError`/`IOError` from `Hive::Gh.pr_frontmatter` — while building
  one item drops that item rather than failing the whole multi-project digest.

## Categorizer Contract

The agent prompt lives in `templates/digest_prompt.md.erb`. It gives the model
one row per shipped item and asks it to write JSON to an exact output path:

```json
{"items":[{"id":"<id>","category":"feature|fix|patrol","summary":"One sentence."}]}
```

IDs are project-scoped via `ShippedItem#categorizer_id`: `<project_name>/<pr_number>`
when a PR number is present, otherwise `<project_name>/<slug>`. The mandatory
`project_name/` prefix keeps two projects that ship the same PR number (or slug)
on one day from colliding onto a single key in the id→row map. Both the PR
**title** and the `pr_body` are wrapped in the per-spawn `user_supplied_<hex>`
tag from `Hive::Stages::Base`, and the prompt instructs the model to treat
everything inside those tags as untrusted data rather than instructions. The
categorizer runs with:

- `status_mode: :output_file_exists`
- `expected_output: <run_dir>/items.json`
- `log_label: "digest"`
- `add_dirs: []`
- `cwd` set to the run directory under `<state_home>/digest/runs/<date>-<hex>`

Agent selection and limits come from the supplied `cfg` hash:

- `digest.agent`, then `patrol.agent`, then `"claude"`.
- `budget_usd.digest`, default `50`.
- `timeout_sec.digest`, default `1800`.

The output mapper is fail-closed on missing/empty/malformed JSON, but
row-level model mistakes are tolerated: an omitted item, invalid category, or
duplicate model id logs a warning (falling back to `$stderr` when no logger is
wired, so the signal can't be configured away), uses category `feature`, and
falls back to the PR title or display label for summary when needed.

## Delivery Contract

`Digest::Sender.resolve_chat_id(cfg)` resolves to `bot.chat_id_allowlist[0]`
only and raises `Hive::ConfigError`
(`"bot.chat_id_allowlist[0] must be configured before sending digest"`) when no
allowlisted chat is set. Dry-run bypasses token and chat lookup entirely.

Real delivery builds `Hive::Bot::Telegram` with
`Hive::Config.telegram_bot_token!` and calls:

```ruby
send_message(chat_id: chat_id, text: text, parse_mode: :markdown_v2)
```

`send_in_chunks` splits a digest longer than Telegram's 4096-char limit into
one `send_message` call per chunk. A mid-stream chunk failure is recorded as a
structured `:send_failure` event on the bot logger (which exposes only
`#event`, not `#error`) and re-raised; the daemon scheduler then retries the
whole date on a later tick (at-least-once delivery across restarts). The
renderer caps each model summary well under the limit so a single rendered
line can never split a MarkdownV2 escape across a chunk boundary.

The default log path is `cfg.dig("bot", "log_file")` or
`<state_home>/logs/bot.log`, sharing the bot logger surface.

## Merged-PR Source

`Hive::Digest::MergedPr` exists under its own namespace so the shipped-task
pipeline remains independent. Bare `hive digest` selects this source unless
`digest.source: shipped` is configured. It reuses:

- `Digest::Window` for the default previous local day and the
  `mergedAt.getlocal.to_date == date` boundary rule.
- `Digest::Stats` / `Hive::Gh.pr_stats` for non-fatal additions, deletions,
  and commit totals.
- `Digest::Renderer.render_footer` for the shared divider and footer format.
- `Digest::Sender` for dry-run / Telegram delivery.
- `Hive::Config.load_global_digest_config` for bot config and `.env` loading on
  real sends.

The repo resolver returns an ordered, case-insensitively de-duped `owner/name`
list. Explicit `repos:` validates slug shape and bypasses discovery;
discovered repos come from `Hive::Config.registered_projects` and
`Gh.repo_name_with_owner(path)`. Partial resolution failures remain warnings,
but an empty registry or an all-failed automatic resolution raises
`Hive::ConfigError` before collection, sender preflight, or delivery. There is
no digest-specific repository configuration key.

The collector queries a broad UTC search window (`D-1` through `D+1`) with
`Gh.list_merged_prs(repo, since:, until_date:)`, then applies the local-date
filter in Ruby. This protects local-midnight boundaries where GitHub's UTC
timestamp date differs from the operator's local calendar date. Each PR record
carries `repo`, `number`, `title`, `url`, raw `mergedAt`, `author`,
`authorIsBot`, `headRefName`, `isCrossRepository`, and optional `hive_slug` /
`hive_stage`.

`MergedPr::HiveMatcher` is intentionally best effort and read-only. It only
recognizes branches shaped `hive/<slug>` and looks for matching directories
under registered projects' `.hive-state/stages/*/<slug>`. Any matcher error
leaves the annotation blank.

After collection, `Digest::Stats#for_items` fetches each record's PR URL.
Individual failures are logged and skipped. The renderer always prints the
known row count (`PRs N`), including `PRs 0`; it prints
`Lines +A/-D · PRs N · Commits C` when at least one PR was measured and omits
Lines/Commits after a total stats blackout. A valid zero-merge day still
renders and is delivered.

The source emits a separate JSON contract, `hive-merged-pr-digest` v1, so
consumers do not need to overload `hive-digest`'s shipped-task statuses.

## Scheduler Contract

`Hive::Daemon::DigestScheduler` is the daemon-side cursor for the daily job.
It persists `last_digested_date` in `<state_home>/digest_state.json` and emits
one global dispatch hash at a time:

```bash
hive digest --source merged-prs --date YYYY-MM-DD --json
```

The due model is local-date based: at any tick, the most recent completed
local day is `Window.local_today(now:) - 1`. Missing state is a first-run guard
that initializes the cursor to that completed day without sending history.
After downtime, owed days dispatch oldest-first, one per successful child
completion, and `digest.max_catchup_days` (default `7`, `0` = unbounded)
skips/logs the oldest excess days. The dispatcher runs this global scheduler
before the status fetch and bypasses per-project daemon gates, but still gates
the dispatch through the concurrency controller (tagged `kind: :digest`, off
the task caps, at most one in flight). A successful child exit advances the
cursor; a non-zero exit clears the pending marker, leaves the cursor for retry,
and records an escalating failure backoff (`60`/`300`/`900`s) so the same date
is **not** re-dispatched every tick. The dispatcher isolates scheduler
`tick` / `complete` exceptions as `fatal` log events with
`keeping_previous: true`, so digest-state I/O faults do not crash the daemon
poll loop. Dry-run pseudo-child reaping calls the same `complete` hook as real
child reaping, which prevents dry-run digest dispatches from wedging behind a
stale pending marker. `digest.enabled`, `digest.source`, and
`max_catchup_days` are re-read on SIGHUP (the scheduler is reconfigured in
place within one tick). A configured `shipped` source changes the explicit
child flag to `--source shipped` without replacing the scheduler or its
pending/backoff state. Completion remains based only on child exit status.

`digest.enabled` is **opt-out**: when the operator has not set it, both
scheduler-config callers load it through `Config.load_global_digest_block`,
which derives the flag ON from the bot config (the bot is enabled with an
allowlisted chat) and OFF otherwise — see [[commands/daemon]] and
[[modules/config]]. An explicit value (true or false) is always honored.

## Tests

- `test/unit/digest/window_test.rb` — local-date parsing and timezone window membership.
- `test/unit/digest/ship_times_test.rb` — ship-commit preference and nil fallback.
- `test/unit/digest/collector_test.rb` — registered-project grouping, missing artifact tolerance, local timezone boundary.
- `test/unit/digest/categorizer_test.rb` — model output mapping, bad-category fallback, missing-row fallback, prompt rendering.
- `test/unit/digest/renderer_test.rb` — category/project ordering, MarkdownV2 escaping, empty/failed messages, no-link rows.
- `test/unit/digest/run_test.rb` — orchestration status branches and default date.
- `test/unit/digest/source_test.rb` — source validation, precedence, conflict handling, and schema identity.
- `test/unit/digest/merged_pr/*_test.rb` — merged-PR repo resolution,
  zero-scope failure, local-date filtering, partial GitHub/stats failure
  tolerance, Hive matching, shared-footer rendering, and runner orchestration.
- `test/unit/digest/sender_test.rb` — chat-id resolution, dry-run bypass, Telegram send args.
- `test/unit/daemon/digest_scheduler_test.rb` — first-run guard, catch-up,
  cap logging, retry, disabled mode, and DST local-date behavior.
- `test/unit/daemon/dispatcher_test.rb` — scheduler dispatch/reap wiring,
  dry-run digest completion, and fatal-log isolation when scheduler completion
  raises.
- `test/digest/e2e_test.rb` — opt-in live model + Telegram fixture run; fails
  loudly when required live env vars are missing.

## Backlinks

- [[commands/digest]]
- [[commands]]
- [[modules/config]]
- [[commands/bot]]
- [[templates]]
