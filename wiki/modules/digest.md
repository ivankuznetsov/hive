---
title: Hive::Digest
type: module
source: lib/hive/digest.rb, lib/hive/digest/, templates/digest_prompt.md.erb
created: 2026-06-14
updated: 2026-06-19
tags: [digest, shipped, telegram, module]
---

**TLDR**: `Hive::Digest` is the library pipeline behind [[commands/digest]].
It finds tasks that reached `9-done` on a requested local date, turns their PR
metadata into `ShippedItem` records, optionally asks an agent to classify and
summarize them, renders Telegram MarkdownV2, and delivers through the existing
bot Telegram client. The module has injectable seams for collector,
categorizer, sender, clock, and config. The default runtime config is loaded
through `Hive::Config.load_global_digest_config`.

## API Map

| API | Purpose |
|-----|---------|
| `Hive::Digest.run(date: nil, dry_run: false, cfg: nil, clock: -> { Time.now }, collector: nil, categorizer: nil, sender: nil)` | Orchestrates collection, categorization/rendering, and delivery. Defaults `cfg` via `Config.load_global_digest_config`. For a real send (not `dry_run`) it first calls `Hive::EnvFile.load!` so `~/.config/hive/.env` supplies `HIVE_TELEGRAM_BOT_TOKEN` even when the environment doesn't export it — this is what lets the daemon-dispatched `hive digest` authenticate (its systemd/detached launch env has no token; previously only `hive bot start` loaded the `.env`, so a daemon-scheduled digest failed preflight with exit 78). An exported env var still wins; a dry-run never loads it. Returns `Result(status:, date:, message:, delivery:)`. |
| `Digest::Window.local_today`, `previous_local_day`, `on_local_date?`, `parse_date`, `parse_time` | Local-date window helpers. `previous_local_day(now:)` is the shared "yesterday local" default used by both the CLI command and `Digest.run`. Collection compares `shipped_at.getlocal.to_date` to the requested date. |
| `Digest::ShipTimes#shipped_at(hive_state_path:, slug:)` | Reads git log on `hive/state` (fixed-string `-F` grep) and picks the ship commit by **action preference** — `pr_finalized`, else `archived`, else approval into `9-done` — not whichever commit is chronologically first. |
| `Digest::Collector#for_date(date)` | Scans registered projects and builds grouped `ShippedItem` rows from `9-done` task folders, `meta.yml`, `pr.md`, and ship times. |
| `Digest::Categorizer#categorize(grouped, date:)` | Renders the digest prompt and runs an `AgentProfile` expecting an `items.json` file. |
| `Digest::Categorizer.map_output_file` / `map_document` | Validates and maps model JSON rows back to shipped items, defaulting bad/missing categories safely. |
| `Digest::Renderer.render`, `.empty`, `.failed`, `.escape_mdv2` | Builds Telegram MarkdownV2 text. |
| `Digest::Sender#deliver(text, dry_run:)` | Returns dry-run text or sends the Telegram MarkdownV2 message (chunked into one `send_message` per chunk above Telegram's 4096-char limit). |

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
  -> Digest::Categorizer (agent writes items.json)
  -> CategorizedItem(item, category, summary)
  -> Digest::Renderer (Telegram MarkdownV2)
  -> Digest::Sender (Telegram bot client)
```

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

## Scheduler Contract

`Hive::Daemon::DigestScheduler` is the daemon-side cursor for the daily job.
It persists `last_digested_date` in `<state_home>/digest_state.json` and emits
one global dispatch hash at a time:

```bash
hive digest --date YYYY-MM-DD --json
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
is **not** re-dispatched every tick. `digest.enabled` / `max_catchup_days` are
re-read on SIGHUP (the scheduler is reconfigured in place within one tick).

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
- `test/unit/digest/sender_test.rb` — chat-id resolution, dry-run bypass, Telegram send args.
- `test/unit/daemon/digest_scheduler_test.rb` — first-run guard, catch-up,
  cap logging, retry, disabled mode, and DST local-date behavior.
- `test/digest/e2e_test.rb` — opt-in live model + Telegram fixture run; fails
  loudly when required live env vars are missing.

## Backlinks

- [[commands/digest]]
- [[commands]]
- [[modules/config]]
- [[commands/bot]]
- [[templates]]
