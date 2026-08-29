---
title: Token Usage Stats
type: observability
source: lib/hive/agent.rb, lib/hive/usage_db.rb, lib/hive/billing_evidence.rb, lib/hive/model_pricing.rb, lib/hive/task_workspace/resources.rb, lib/hive/task_workspace/usage.rb, config/model-pricing.v1.yml, lib/hive/patrol/launch_budget.rb, lib/hive/agent_profiles/usage_extractors.rb, lib/hive/tui/views/token_stats.rb, lib/hive/tui/bubble_model.rb
created: 2026-05-24
updated: 2026-08-29
tags: [observability, usage, pricing, billing, tui, sqlite, agent]
---

**TLDR**: Hive records evidence-backed usage for Hive-driven agent spawns. The
runtime keeps unknown token categories distinct from numeric zero, and the
launch receipt keeps harness, actual provider/model, and `api`, `subscription`,
or `unknown` billing evidence separate. Semantic task inspection joins every
exactly bound failed/retried/current session once, shows known input-plus-output
tokens, and calculates a coverage-labelled API-equivalent estimate from a
versioned local first-party price catalog. That estimate is not an invoice or
provider health signal. Fleet/TUI aggregates remain telemetry; Hive does no
historical log backfill and ingests no ad-hoc sessions.

## Capture Boundary

Usage is captured at the same boundary that runs stage agents:

1. `Hive::Agent#spawn_and_wait` reads every stdout/stderr line from the child process, writes it to the stage log, parses JSON once, and passes decoded records through `Hive::AgentRuntime.extract_usage`, which delegates provider decoding to `agent-cli-runtime`.
2. The last non-nil usage hash normally becomes `result[:usage]`; `result[:model]` is kept as a best-effort model field. When `max_tokens` is present, `Hive::Agent::StreamTokenMeter` also derives a monotonic live input-plus-output total; cached tokens remain in telemetry but do not advance the stop meter. Reaching the limit sends TERM, escalates to KILL after a three-second grace independently of the wall-clock timeout, returns `resource_exhaustion.reason: token_limit`, and records the meter's aggregate usage. Patrol Claude reviews stop after their expected output or four completed turns, with the fourth reserved for emergency finalization. Ordinary fixes also treat a completed `fix.json` as the agent-phase boundary; Hive still independently parses and validates its proof and edits. Because Claude can emit `Write` and the same turn's final usage delta in either order, Hive allows up to three seconds for the missing protocol event, captures it when present, and terminates before another model turn. A completed artifact remains subject to the caller's schema and evidence validation.
3. `Hive::Stages::Base.spawn_agent` calls `Hive::UsageDb.record!` after `agent.run!` returns, even when the spawn exits non-zero, as long as a usage event was captured.
4. Patrol is not a stage runner, so `Hive::Patrol::LaunchBudget` records scheduled ordinary review launches as `patrol-review-unmetered` and scheduled current-main Architecture launches as `refactor-patrol-review-unmetered` before the provider child starts, with `project_slug` set to the registered project name. These standalone launches keep a durable `session_id` but no `attempt_id`: Hive never invents an Attempts row merely to satisfy telemetry attribution. Normal completion updates that same session row with final telemetry and removes the `-unmetered` suffix only when positive usage is present. Fix stages write completion telemetry without requesting discovery admission; merged-PR Architecture reviews use a non-discovery telemetry source. An abandoned scheduled reservation is an observed launch, not a claim that the provider consumed zero tokens.

That placement deliberately excludes sessions launched outside Hive and avoids scraping `~/.claude/projects/*.jsonl` or any on-disk agent log after the fact. See [[modules/agent]], [[modules/agent_profile]], [[modules/patrol]], and [[stages/index]].

## Agent Extractors

`agent-cli-runtime` owns the concrete parsers;
`lib/hive/agent_profiles/usage_extractors.rb` is the compatibility alias:

| Agent | Event shape |
|-------|-------------|
| `claude` | Reads terminal `result` totals plus `stream_event` message-start/delta usage, including nested `event.message.usage`. The live meter sums completed turns without double-counting cumulative output deltas. |
| `codex` | accepts supported terminal/turn usage shapes; omitted categories remain unavailable rather than zero. |
| `pi` | accepts supported terminal/completion shapes; omitted categories remain unavailable rather than zero. |
| `grok` | accepts a real usage object if a future streaming event supplies one; current `end` events contain no counts, so the extractor returns nil rather than fabricating zero usage. |
| `opencode` | uses the strict run/export normalizer. Sanitized export supplies authoritative input, output, cache-read, cache-write, reasoning, and cost values; unavailable fields remain nil and numeric zero remains zero. |

Extractor output preserves nullable input, output, cache-read, cache-write, and
reasoning counts plus explicit inclusion semantics. A numeric zero means the
runtime observed zero; `nil` means it could not establish the value.

## Storage

`Hive::UsageDb` uses the installation-wide runtime control plane at:

```ruby
Hive::Paths.runtime_control_plane_path
```

On a normal Linux desktop that resolves to
`~/.local/state/hive/runtime-control-plane.sqlite3`. Normal reads and writes
open the exact activated schema through the shared Sequel owner; they never
create or migrate it. `Hive::UsageDb.database=` is the test seam for an
explicitly migrated fixture. The retired `HIVE_USAGE_DB_PATH` variable and
standalone `usage.db` are migration inputs only, not runtime configuration.

Schema:

| Column | Meaning |
|--------|---------|
| `id` | UUID primary key. |
| `agent` | Profile name, for example `claude`, `codex`, `pi`, `grok`, or `opencode`. |
| `model` | Best-effort model name from the usage event; OpenCode uses its observed actual route when export proved it. |
| `requested_backend` / `requested_model` | OpenCode's requested nested route, stored separately from actual identity. |
| `actual_backend` / `actual_model` | Sanitized-export-observed OpenCode route, or nil when unavailable. |
| `project_slug` | `task.project_name`, intentionally path-independent so multiple checkouts collapse. |
| `task_slug` | Hive task slug. |
| `stage` | Stage name at spawn time, for example `4-execute`. |
| `attempt_id` / `session_id` | Nullable exact durable attribution for workspace-aware launches. A partial unique index makes a non-null session idempotent. |
| `task_generation` | Nullable task generation bound to that attempt/session observation. |
| `source` | Nullable symbolic producer of the attributed observation. |
| `started_at` / `ended_at` | UTC ISO8601 timestamps. |
| `input` / `output` / `cached` | Backward-compatible aggregate counters. Claude cached tokens are cache-read plus cache-creation input tokens. Unknown detailed values store numeric zero here only for legacy aggregation and have a false availability flag. |
| `cache_read` / `cache_write` / `reasoning` / `cost` | Nullable detailed usage. `cost` is provider-reported comparison evidence and does not drive Hive's estimate. |
| `*_available` | Per-field evidence flags preserving unavailable separately from numeric zero. Existing databases gain these additive columns in place; legacy input/output/cached rows are marked available and newly introduced details unavailable. |
| `billing_route` / `billing_evidence_source` | Launch-bound `subscription`, `api`, or `unknown`, with `provider_account_config`, `agent_profile_contract`, or `unavailable` evidence. |
| `input_includes_cache_read` / `input_includes_cache_write` / `output_includes_reasoning` | Nullable inclusion semantics used to prevent overlapping token charges. |

Indexes cover `started_at`, `(project_slug, started_at)`, `(task_slug,
started_at)`, and exact attempt/generation attribution. The fleet cutover owns
legacy import and schema migration; `UsageDb` contains no raw SQLite schema or
self-migration path. Legacy rows remain explicitly unattributed: Hive never
joins them to an attempt from similar timestamps. Session writes are
idempotent upserts in bounded immediate transactions. An exact attributed read
failure is `available: false`, not zero usage, while an authoritative write
failure raises a typed runtime-control-plane error and cannot be acknowledged
as successful accounting.

Conflicting non-unknown billing routes, attempt/generation ownership, or token
inclusion flags cannot overwrite an existing exact session. Direct Claude,
Codex, and Grok profiles can prove subscription semantics from their profile
contract. Pi and OpenCode remain `unknown` unless an admitted provider-account
configuration explicitly declares the route. Harness identity is never used as
the billing provider.

## Semantic task usage

`Hive::TaskWorkspace::Usage` starts from the bounded durable attempt/session
inventory, then performs exact `UsageDb.exact_attempt` reads. It includes failed
attempts and retries, deduplicates by durable session ID, rejects rows not bound
to that inventory, and reports unattributed legacy rows separately.
The v1 resource and v2 semantic projections share one request-local reader:
each attempt is read at most once, no attempt returns more than 100 sessions,
and the complete task read has one two-second monotonic deadline. Exhaustion,
truncation, and store failures lower coverage and never become zero usage.
The task coverage vocabulary is:

- `complete` — every bounded session is terminal, metered, attributable, and
  priceable;
- `partial` — the visible values are an observed subtotal because sessions,
  token categories, modifiers, or the attempt window are missing;
- `pending` — at least one exact session is still live;
- `unavailable` — no durable session inventory or trustworthy usage is
  available.

The summary publishes known input-plus-output tokens, harness sets, evidenced
actual providers/models, combined billing route, and API-equivalent coverage.
Details group sessions by stage/outcome and retain cache/reasoning categories,
billing evidence, rate basis, and missing dimensions. Raw attempt/session IDs
are not headings, and the v2 projection removes provider-reported cost.

## API-equivalent price catalog

`config/model-pricing.v1.yml` is a versioned, request-time-network-free catalog
of first-party OpenAI, Anthropic, and xAI USD-per-million-token rates. Each card
binds provider, canonical model/aliases, effective interval, lifecycle,
official HTTPS source URL, catalog check date, required request dimensions,
rates, and modifiers. The validator accepts only the official hosts
`developers.openai.com`, `platform.claude.com`, and `docs.x.ai`.

`Hive::ModelPricing` selects a card by actual provider/model and session time,
uses `BigDecimal`, and calculates non-overlapping provider-aware input,
cache-read, cache-write, and output quantities. It applies evidenced
long-context, service-tier, cache-write-TTL, inference-geography, reasoning,
and server-tool semantics. A missing or unsupported required modifier produces
`partial` or `unavailable` instead of guessing. The calculation sums exact
decimals before Web display rounding.

The catalog was checked on 2026-08-16 against the URLs stored on every card.
It is maintainer-owned historical data: a refresh updates checked/effective
metadata and retains old time-bounded cards rather than changing historical
task estimates. API-equivalent values answer “what would these evidenced tokens
cost at the matching public API rate?” They do not claim provider-observed
spend, subscription allocation, credits, taxes, negotiated discounts, quota,
credential validity, or live provider health.

## Task workspace resource truth

The task workspace keeps configured guards and observed use separate. Each
resource identifies its kind, unit, scope, configuration source, enforcement
state, configured value, observed value, and reset/retry timing. Monetary API
caps, subscription-backed budget-equivalent guards, token ceilings, launch
quotas, and wall-clock timeouts never collapse into one budget. In particular,
a subscription-backed `budget_usd` guard is not described as billed spend.

Remaining headroom is computed only when configured and observed values have
the same trustworthy unit and scope. Unknown persistence, live usage that has
not yet landed, and unattributed legacy rows remain unavailable rather than
zero. Aggregation deduplicates by exact session ID before rolling up to the
attempt. See [[modules/task_workspace]].

## Aggregates

`Hive::UsageDb.aggregate(scope:, now:)` returns per-agent and total buckets for:

- `today`: UTC day boundary.
- `7d`: rolling `now - 7 days`.
- `30d`: rolling `now - 30 days`.
- `all`: no time filter.

The scope hash accepts `project_slug:` and `task_slug:` filters. `task_slug` is normally paired with `project_slug` by the TUI so same-named tasks in different projects stay distinguishable.

The aggregate also returns `:patrol` buckets by summing rows whose `stage` starts with `patrol` **or** `refactor-patrol`, honoring the same scope and time-window filters. This is a cross-cutting attribution bucket: patrol tokens still belong to their actual agent rows (`claude`, `codex`, `pi`, `grok`, or `opencode`) and still contribute to `TOTAL`; the patrol bucket is not added into `TOTAL` a second time.

`Hive::UsageDb.patrol_activity` remains the current-UTC-day telemetry source for
input/output/cached totals, aggregate Patrol launches, engine attribution, and
unmetered counts. Admission instead uses the bounded owner-private Patrol
allowance rows in the same control plane. Their independent ordinary and Architecture
lanes are keyed by stable project ID and UTC date and follow the selected mode's
16/8/4/2 ceiling. An atomic pre-spawn reservation survives controller loss.
Daily exhaustion resets at the next UTC date; provider retry holds are durable
per lane and may cross midnight. Fix/review/publish/remediation and post-merge
work do not consume scheduled discovery allowance.

On the first day after this ledger is introduced, exact legacy discovery rows
seed their corresponding engine lane while known fix/non-discovery rows are
excluded. Ambiguous attribution parks only that lane until the next UTC day.
After seeding, UsageDb failures affect telemetry but cannot create or remove
capacity. Existing wall-clock, turn, process-custody, feature, fix, and PR caps
remain independent controls.

## TUI Surfaces

`hive tui` shows a compact usage block in the grid-mode footer. On wide terminals, the keybinding hints render first, then ` · `, then the compact usage block so right-side truncation clips token counters before actions. Below 80 usable columns, the existing compact-only footer path still renders just the usage block. The compact block intentionally omits the `30d` bucket; use the full `T` matrix for that window:

```text
[Tab] switch ... [q] quit · today 1.2M/400k/200k • 7d ... • all ... • tokens
```

The tuple is `input/output/cached`. Units use `k` and `M` with compact one-decimal formatting. Footer scope follows the current selection:

- all projects when no concrete project/task is selected,
- project when the left pane is focused on a project,
- task when the right pane has a focused row.

Press `T` in grid mode to open the full-screen token matrix. It renders `claude`, `codex`, `pi`, `grok`, `opencode`, `patrol`, and `TOTAL` rows across `today`, `7d`, `30d`, and `all`. The `patrol` row is the attribution lens described above, not an extra summand. In the stats mode:

- `Left` / `Right` or `h` / `l` drill between all, project, and task scope.
- `Up` / `Down` or `k` / `j` select the project or task at the current drill level.
- `q` / `Esc` closes back to the grid.

See [[commands/tui]] for the broader TUI mode and keybinding contract.

## Tests

- `test/unit/usage_db_test.rb`
- `test/unit/model_pricing_test.rb`
- `test/unit/task_workspace/usage_test.rb`
- `test/integration/task_command_test.rb`
- `test/unit/patrol/launch_budget_test.rb`
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
- [[modules/task_workspace]]
- [[stages/index]]
- [[gaps]]
