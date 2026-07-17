---
title: Token Usage Stats
type: observability
source: lib/hive/agent.rb, lib/hive/usage_db.rb, lib/hive/patrol/token_budget.rb, lib/hive/agent_profiles/usage_extractors.rb, lib/hive/tui/views/token_stats.rb, lib/hive/tui/bubble_model.rb
created: 2026-05-24
updated: 2026-07-16
tags: [observability, tui, sqlite, agent]
---

**TLDR**: Hive records token usage only for hive-driven agent spawns. `Hive::Agent#spawn_and_wait` captures the last structured usage event seen in the child stream, `Hive::Stages::Base.spawn_agent` writes one SQLite row after normal stage spawns, and ordinary plus architecture patrol wrappers write project-scoped rows after every default agent launch. Patrol launches without trustworthy positive counts use an `-unmetered` stage suffix and still consume provider-independent launch quota. `hive tui` surfaces scoped aggregates in the footer plus a full-screen `T` matrix with a patrol attribution row. There is no historical log backfill and no ingestion of ad-hoc agent sessions.

## Capture Boundary

Usage is captured at the same boundary that runs stage agents:

1. `Hive::Agent#spawn_and_wait` reads every stdout/stderr line from the child process, writes it to the stage log, parses JSON once, and passes decoded records to the current `Hive::AgentProfile#usage_extractor`.
2. The last non-nil usage hash normally becomes `result[:usage]`; `result[:model]` is kept as a best-effort model field. When `max_tokens` is present, `Hive::Agent::StreamTokenMeter` also derives a monotonic live total. Reaching the limit sends TERM, escalates to KILL after a three-second grace independently of the wall-clock timeout, returns `resource_exhaustion.reason: token_limit`, and records the meter's aggregate usage. Patrol Claude reviews also stop at three completed turns or after their expected output artifact appears. Because Claude can emit `Write` and the same turn's final usage delta in either order, Hive allows up to three seconds for the missing protocol event, captures it when present, and terminates before another model turn. A completed artifact remains subject to the caller's schema and evidence validation.
3. `Hive::Stages::Base.spawn_agent` calls `Hive::UsageDb.record!` after `agent.run!` returns, even when the spawn exits non-zero, as long as a usage event was captured.
4. Patrol is not a stage runner, so `Hive::Patrol::TokenBudget` records ordinary review/fix launches as `patrol-review` / `patrol-fix` and architecture launches as `refactor-patrol-review` / `refactor-patrol-fix`, with `project_slug` set to the project folder basename. Missing or all-zero usage becomes `<stage>-unmetered`; this is an observed launch, not a claim that the provider consumed zero tokens.

That placement deliberately excludes sessions launched outside Hive and avoids scraping `~/.claude/projects/*.jsonl` or any on-disk agent log after the fact. See [[modules/agent]], [[modules/agent_profile]], [[modules/patrol]], and [[stages/index]].

## Agent Extractors

`lib/hive/agent_profiles/usage_extractors.rb` holds the concrete parsers:

| Agent | Event shape |
|-------|-------------|
| `claude` | Reads terminal `result` totals plus `stream_event` message-start/delta usage, including nested `event.message.usage`. The live meter sums completed turns without double-counting cumulative output deltas. |
| `codex` | accepts known final result / turn-completed JSON shapes and zero-fills when a usage payload is absent. |
| `pi` | accepts known final result / completion JSON shapes and zero-fills when a usage payload is absent. |
| `grok` | accepts a real usage object if a future streaming event supplies one; current `end` events contain no counts, so the extractor returns nil rather than fabricating zero usage. |

Codex and Pi payload shapes still need refinement from captured real streams; the zero-fill path keeps one row per Hive spawn without pretending unknown usage is known. The follow-up is tracked in [[gaps]].

## Storage

`Hive::UsageDb.path` defaults to:

```ruby
File.join(Hive::Paths.data_home, "usage.db")
```

On a normal Linux desktop that resolves to `~/.local/share/hive/usage.db`. Tests and operators can override it with `Hive::UsageDb.path=` or `HIVE_USAGE_DB_PATH`.

Schema:

| Column | Meaning |
|--------|---------|
| `id` | UUID primary key. |
| `agent` | Profile name, for example `claude`, `codex`, `pi`, or `grok`. |
| `model` | Best-effort model name from the usage event. |
| `project_slug` | `task.project_name`, intentionally path-independent so multiple checkouts collapse. |
| `task_slug` | Hive task slug. |
| `stage` | Stage name at spawn time, for example `4-execute`. |
| `started_at` / `ended_at` | UTC ISO8601 timestamps. |
| `input` / `output` / `cached` | Token counters. Claude cached tokens are cache-read plus cache-creation input tokens. |

Indexes cover `started_at`, `(project_slug, started_at)`, and `(task_slug, started_at)`.

## Aggregates

`Hive::UsageDb.aggregate(scope:, now:)` returns per-agent and total buckets for:

- `today`: UTC day boundary.
- `7d`: rolling `now - 7 days`.
- `30d`: rolling `now - 30 days`.
- `all`: no time filter.

The scope hash accepts `project_slug:` and `task_slug:` filters. `task_slug` is normally paired with `project_slug` by the TUI so same-named tasks in different projects stay distinguishable.

The aggregate also returns `:patrol` buckets by summing rows whose `stage` starts with `patrol` **or** `refactor-patrol`, honoring the same scope and time-window filters. This is a cross-cutting attribution bucket: patrol tokens still belong to their actual agent rows (`claude`, `codex`, `pi`, or `grok`) and still contribute to `TOTAL`; the patrol bucket is not added into `TOTAL` a second time.

`Hive::UsageDb.patrol_activity` is the runtime enforcement view for the current UTC day. It returns input/output/cached and their conservative sum, total patrol agent launches, and unmetered launches. `Hive::Patrol::TokenBudget` checks that durable project-wide view before each default ordinary or architecture patrol spawn, while also retaining an in-process cycle counter if SQLite recording fails. A project-keyed `flock` is acquired before that check and held until usage is recorded, serializing all ordinary and architecture agent lifetimes for the project; a competing process cannot reserve the same daily remainder and fails closed as `agent_in_flight`, while a crash releases the kernel lock automatically. Cached tokens count toward every ceiling. Before spawning, `Hive::Patrol::AgentLaunch` requires enough remaining per-agent/cycle/day allowance for the profile's `initial_context_tokens` plus one token per rendered prompt byte. Claude reserves 20,000 initial-context tokens, covering the provider context sent before its first measurable stream event; insufficient headroom returns `insufficient_launch_headroom` without a child or usage row. Hive then passes the smallest of the mode's per-agent limit and the remaining cycle/day allowances into each running review/fix agent: low/medium/high/ultrapatrol use at most 40k/50k/75k/100k for ordinary launches, and architecture uses the configured multiplier (2x by default) until the shared daily remainder becomes smaller. The native dollar-equivalent guard is not multiplied. Claude's interim events make that an actual in-flight stop, subject to the granularity of provider events. Providers that expose usage only in their terminal event can be marked over-limit then, but cannot be interrupted early from token data; provider-independent launch caps and wall-clock timeouts remain the fallback. The CLI calls the native guard a USD budget; on subscription-backed providers it does not mean Hive makes an additional payment.

## TUI Surfaces

`hive tui` shows a compact usage block in the grid-mode footer. On wide terminals, the keybinding hints render first, then ` · `, then the compact usage block so right-side truncation clips token counters before actions. Below 80 usable columns, the existing compact-only footer path still renders just the usage block. The compact block intentionally omits the `30d` bucket; use the full `T` matrix for that window:

```text
[Tab] switch ... [q] quit · today 1.2M/400k/200k • 7d ... • all ... • tokens
```

The tuple is `input/output/cached`. Units use `k` and `M` with compact one-decimal formatting. Footer scope follows the current selection:

- all projects when no concrete project/task is selected,
- project when the left pane is focused on a project,
- task when the right pane has a focused row.

Press `T` in grid mode to open the full-screen token matrix. It renders `claude`, `codex`, `pi`, `grok`, `patrol`, and `TOTAL` rows across `today`, `7d`, `30d`, and `all`. The `patrol` row is the attribution lens described above, not an extra summand. In the stats mode:

- `Left` / `Right` or `h` / `l` drill between all, project, and task scope.
- `Up` / `Down` or `k` / `j` select the project or task at the current drill level.
- `q` / `Esc` closes back to the grid.

See [[commands/tui]] for the broader TUI mode and keybinding contract.

## Tests

- `test/unit/usage_db_test.rb`
- `test/unit/patrol/token_budget_test.rb`
- `test/unit/usage_extractors_test.rb`
- `test/integration/stages_base_usage_test.rb`
- `test/unit/tui/views/usage_footer_test.rb`
- `test/integration/tui_usage_footer_test.rb`
- `test/unit/tui/views/token_stats_test.rb`
- `test/integration/tui_token_stats_test.rb`

## Backlinks

- [[commands/tui]]
- [[modules/agent]]
- [[modules/agent_profile]]
- [[stages/index]]
- [[gaps]]
