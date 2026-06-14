---
title: Hive::Digest
type: module
source: lib/hive/digest.rb, lib/hive/digest/, templates/digest_prompt.md.erb
created: 2026-06-14
updated: 2026-06-14
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
| `Hive::Digest.run(date: nil, dry_run: false, cfg: nil, clock: -> { Time.now }, collector: nil, categorizer: nil, sender: nil)` | Orchestrates collection, categorization/rendering, and delivery. Defaults `cfg` via `Config.load_global_digest_config`. Returns `Result(status:, date:, message:, delivery:)`. |
| `Digest::Window.local_today`, `on_local_date?`, `parse_date`, `parse_time` | Local-date window helpers. Collection compares `shipped_at.getlocal.to_date` to the requested date. |
| `Digest::ShipTimes#shipped_at(hive_state_path:, slug:)` | Reads git log on `hive/state` and chooses the first ship commit by action preference: `pr_finalized`, `archived`, then approval into `9-done`. |
| `Digest::Collector#for_date(date)` | Scans registered projects and builds grouped `ShippedItem` rows from `9-done` task folders, `meta.yml`, `pr.md`, and ship times. |
| `Digest::Categorizer#categorize(grouped, date:)` | Renders the digest prompt and runs an `AgentProfile` expecting an `items.json` file. |
| `Digest::Categorizer.map_output_file` / `map_document` | Validates and maps model JSON rows back to shipped items, defaulting bad/missing categories safely. |
| `Digest::Renderer.render`, `.empty`, `.failed`, `.escape_mdv2` | Builds Telegram MarkdownV2 text. |
| `Digest::Sender#deliver(text, dry_run:)` | Returns dry-run text or sends one Telegram MarkdownV2 message. |

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
- Malformed PR frontmatter is handled by `Hive::Gh.pr_frontmatter`.
- `Hive::GitError` while building one item drops that item rather than failing
  the whole digest.

## Categorizer Contract

The agent prompt lives in `templates/digest_prompt.md.erb`. It gives the model
one row per shipped item and asks it to write JSON to an exact output path:

```json
{"items":[{"id":"<id>","category":"feature|fix|patrol","summary":"One sentence."}]}
```

IDs are `pr_number` when present, otherwise the task slug. `pr_body` is wrapped
in the normal per-spawn `user_supplied_<hex>` tag from `Hive::Stages::Base`.
The categorizer runs with:

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
row-level model mistakes are tolerated: an omitted item or invalid category
logs a warning, uses category `feature`, and falls back to the PR title or
display label for summary when needed.

## Delivery Contract

`Digest::Sender.resolve_chat_id(cfg)` prefers `bot.digest_chat_id`, then the
first `bot.chat_id_allowlist` entry. Missing both raises `Hive::ConfigError`.
Dry-run bypasses token and chat lookup entirely.

Real delivery builds `Hive::Bot::Telegram` with
`Hive::Config.telegram_bot_token!` and calls:

```ruby
send_message(chat_id: chat_id, text: text, parse_mode: :markdown_v2)
```

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
After downtime, owed days dispatch oldest-first, one per child completion, and
`digest.max_catchup_days` (default `7`) skips/logs the oldest excess days.
The dispatcher runs this global scheduler before the status fetch and bypasses
per-project daemon gates; successful child exit advances the cursor, while a
non-zero exit clears the pending marker but leaves the cursor for retry.

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
