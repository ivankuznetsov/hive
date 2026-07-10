---
title: Token Usage Stats
type: observability
source: lib/hive/usage_db.rb, lib/hive/agent_profiles/usage_extractors.rb, lib/hive/tui/views/token_stats.rb, lib/hive/tui/bubble_model.rb
created: 2026-05-24
updated: 2026-07-10
tags: [observability, tui, sqlite, agent]
---

**TLDR**: Hive records token usage only for hive-driven agent spawns. `Hive::Agent#spawn_and_wait` captures the last structured usage event seen in the child stream, `Hive::Stages::Base.spawn_agent` writes one SQLite row after normal stage spawns, patrol reviewer/fixer wrappers write `patrol-*` rows after patrol agent spawns, and `hive tui` surfaces scoped aggregates in the footer plus a full-screen `T` matrix with a patrol attribution row. There is no historical log backfill and no ingestion of ad-hoc agent sessions.

## Capture Boundary

Usage is captured at the same boundary that runs stage agents:

1. `Hive::Agent#spawn_and_wait` reads every stdout/stderr line from the child process, writes it to the stage log, parses JSON once, and passes decoded records to the current `Hive::AgentProfile#usage_extractor`.
2. The last non-nil usage hash becomes `result[:usage]`; `result[:model]` is kept as a best-effort model field.
3. `Hive::Stages::Base.spawn_agent` calls `Hive::UsageDb.record!` after `agent.run!` returns, even when the spawn exits non-zero, as long as a usage event was captured.
4. Patrol is not a stage runner, so `Hive::Patrol::Reviewer` and `Hive::Patrol::Fixer` call `Hive::UsageDb.record!` directly after their default `run_agent` wrappers return. They use `stage` / `task_slug` values of `patrol-review` and `patrol-fix`, with `project_slug` set to the project folder basename.

That placement deliberately excludes sessions launched outside Hive and avoids scraping `~/.claude/projects/*.jsonl` or any on-disk agent log after the fact. See [[modules/agent]], [[modules/agent_profile]], [[modules/patrol]], and [[stages/index]].

## Agent Extractors

`lib/hive/agent_profiles/usage_extractors.rb` holds the concrete parsers:

| Agent | Event shape |
|-------|-------------|
| `claude` | `type == "result"`; reads `usage.input_tokens`, `usage.output_tokens`, and sums `usage.cache_read_input_tokens + usage.cache_creation_input_tokens`. |
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

The aggregate also returns `:patrol` buckets by summing rows whose `stage` starts with `patrol`, honoring the same scope and time-window filters. This is a cross-cutting attribution bucket: patrol tokens still belong to their actual agent rows (`claude`, `codex`, `pi`, or `grok`) and still contribute to `TOTAL`; the patrol bucket is not added into `TOTAL` a second time.

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
