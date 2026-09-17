---
title: Polished Token Usage Analytics - Revised Plan
type: feat
date: 2026-09-14
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: hive-brainstorm
origin: .hive-state/stages/3-plan/add-a-polished-token-usage-260813-f194/brainstorm.md
execution: code
---

# Polished Token Usage Analytics - Revised Plan

## Overview

This revision preserves U1–U4 and the curated product decisions, with current source checks and explicit degraded-data behavior. This stage changes only this plan; implementation and test execution belong to the next stage.

Build a first-class, read-only Token Usage page in Hive Web that shows where Hive spent tokens during a selected period and highlights unusually large projects or tasks. Add one reusable, status-aware reporting projection over `Hive::UsageDb`, which is a facade over the installation-wide runtime control plane. Rails consumes that projection without duplicating aggregation rules, creating another telemetry store, or changing the control-plane schema.

The page leads with observed Input, Output, Cached, and `TOTAL` values, selected-scope coverage, top consumers, and a reconciled trend. It also exposes project, agent/provider, best-effort model, workflow/stage, task, and patrol breakdowns. Complete telemetry must reconcile with the TUI; incomplete telemetry remains visibly incomplete rather than becoming zero.

## Goal Capsule

- **Goal:** Make token consumption and unexpectedly large consumers understandable at a glance, with honest coverage and drill-down behavior.
- **Primary actor:** A Hive operator using the native Web UI.
- **Primary decision:** “Where did Hive spend tokens during this period, and is any project or task consuming unexpectedly much?”
- **Deliverable:** A reviewed, tested Web feature plus its shared reporting contract and documentation.
- **Non-goals:** Cost estimates, historical backfill, ad-hoc-session ingestion, arbitrary multi-dimension querying, custom dates, schema migration, release work, or a second telemetry system.

## Product Contract

### Requirements

- **R1 — Native entry point and hierarchy.** Add Token Usage to authenticated Hive Web navigation. Lead with selected-period observed usage, coverage, top projects, and top tasks.
- **R2 — Existing truth source and capture boundary.** Read the existing control-plane-backed `Hive::UsageDb` only. Include Hive-driven spawns already covered by that store. Do not expose prompts, logs, raw rows/errors, local paths, or attempt/session identifiers.
- **R3 — Exact arithmetic.** Present Input, Output, Cached, and `TOTAL` with accessible exact integers. Preserve `TOTAL = input + output`; Cached is attribution within input/total and is never added again. Do not estimate cost or charged tokens.
- **R4 — Range parity.** Support `today`, rolling `7d`, rolling `30d`, and `all` using current `Hive::UsageDb` UTC cutoffs. Custom ranges remain excluded.
- **R5 — Consistent exploration.** Provide reconciled trend and ranked views for project, agent, observed provider, best-effort model, workflow, stage, project-qualified task, and patrol/non-patrol. A selected value updates summary, trend, selected-scope metered/unmetered coverage, and every remaining breakdown from the same accepted-row set. `rejected_count` is computed before filtering and remains explicitly database-wide because rejected rows may lack usable dimensions or timestamps.
- **R6 — URL-owned filters.** Permit a range plus exactly one selected project, agent, provider, model, workflow, stage, task, or patrol value. Selecting another value replaces it. Refresh and browser history reproduce the state.
- **R7 — Patrol is a partition.** Offer all/patrol/non-patrol as a page-wide lens and render patrol versus non-patrol as a reconciled partition, never as an extra summand.
- **R8 — Honest component-aware coverage.** Label numeric results as observed. Input/output availability determines each component's contribution to `TOTAL`; incomplete input/output coverage makes a usable result partial. Cached availability is tracked independently: a cached-only gap leaves the total computable, but always produces a persistent partial-telemetry/cached-coverage warning and detail. Keep selected-scope metered/unmetered counts and database-wide rejected count visible when applicable. Treat unavailable fields, zero-filled unknown data, and `*-unmetered` records as unknown coverage, not confirmed zero.
- **R9 — Control-plane-aware states.** Distinguish data empty from installation/control-plane failure. Use `RuntimeControlPlane::Diagnosis`: `missing` and `unrelated_database` are unavailable; `older_schema`, `newer_schema`, `missing_schema`, and `partial_schema` are migration/incompatible states with specific safe operator copy; `corrupt` is corrupt; only an `ok` control plane with no raw usage rows is source-empty. All-rejected data is non-numeric degraded; a valid filter with no accepted rows is selection-empty with any global rejection warning retained. No unavailable, migration-required, incompatible, or corrupt state renders numeric zero, and no usage-page error takes down other Web pages.
- **R10 — Native, accessible, responsive presentation.** Follow Hive Web’s layout, palette, dark mode, cards/tables, and mobile navigation. Charts have semantic equivalents, exact values work by pointer and keyboard, and common phone widths do not overflow.
- **R11 — Evidence and documentation.** Cover arithmetic, range parity, dimensions, URL navigation, workflow attribution, coverage, diagnosis states, bounded reconciliation, accessibility, and desktop/mobile rendering. Update user-facing/Wiki docs and add a Wiki log fragment.
- **R12 — Delivery boundary.** End with reviewed code, tests, docs, and evidence. Do not tag, release, deploy, publish, merge, or choose a version.

### Key Technical Decisions

1. Keep `Hive::UsageDb.aggregate` backward-compatible for the TUI; add `Hive::UsageReport` as the richer typed projection.
2. Open and diagnose the shared runtime control plane through its existing database API. Do not create a missing database from a Web request, bypass `schema_info`, mutate schema, or add a migration.
3. Add optional `task_id:` to `UsageDb.record!` and persist it in the already-existing nullable `token_usage.task_id` string column. It has no database foreign-key constraint. `Stages::Base#record_usage` supplies the stable registered task ID for task-stage rows. Patrol or legacy call sites without a registered task may leave it nil; unmatched IDs remain usable telemetry with Unknown workflow.
4. Derive workflow by a left join from `token_usage.task_id` to `task_subjects.task_id` and use `task_subjects.workflow_id`. Unlinked legacy/patrol rows render as `Unknown`; there is no historical backfill or parallel denormalized workflow column.
5. Normalize and validate rows once, before range/dimension filtering. The real schema already prevents null/negative core counts and invalid availability flags; production rejection is therefore principally malformed timestamp/defensive decoding. Retain defence-in-depth validation for injected row sources, but document those impossible-under-schema branches as fixture-only and do not imply rejected production data is expected.
6. Read once per request inside one short, non-transactional `RuntimeControlPlane::Database#read` checkout; materialize only required reporting fields, release the single-connection `ProcessGuard` checkout before aggregation/rendering, and never hold it across template work or external I/O.
7. Bound rankings with an `Other` remainder. Bound all-time monthly trend output with an explicit earliest `Earlier` overflow bucket containing every omitted old month so visible buckets still reconcile exactly to the observed selected total. Daily buckets remain bounded for shorter ranges.
8. State precedence is non-overlapping: diagnosis/read failure first; then all-rejected (non-numeric degraded); then source-empty only when the raw source has no rows; then selection-empty; then no-metered-total; then `partial` for incomplete input/output coverage; otherwise `ready`. Rejection and cached coverage are persistent independent warning flags, including on an empty selection. Any rejected rows make the overall presentation degraded; cached-only gaps retain a computable total but still show partial telemetry coverage.

## Scope Boundaries

- Include the four existing ranges, one URL-owned dimension selection, all required breakdowns, accessible charts/tables, coverage/failure states, and documentation/evidence.
- Patrol occupies the same single dimension slot as project/model/etc. Selecting patrol replaces a project filter and vice versa; it does not add a second simultaneous filter. Clearing the slot keeps the range and restores all-project/all-work scope. Default range is `7d`.
- Preserve existing TUI sums and UTC lower-bound comparisons, including the absence of an upper cutoff; do not silently exclude future-dated valid records. Reuse the same cutoff helper and comparison semantics in the report. Group trend labels in UTC and keep all selected rows represented.
- Do not add prices, billing/cost views, alerts, anomaly thresholds, custom ranges, arbitrary combined dimensions, live auto-refresh, new chart dependencies, telemetry stores, historical backfill, or ingestion from ad-hoc sessions.
- No external task prerequisite is known; `meta.yml` declares none. U1–U4 ordering is internal implementation sequencing, not a scheduler dependency.
- The daemon owns reviewed coding-stage advancement. This plan authorizes no release, tag, deploy, publication, merge, or version selection.

### Reporting details shared by U1–U3

- Sum observed input and output independently using their availability evidence; `TOTAL` is their sum. Never discard known input merely because output is unknown. A row is fully metered for total coverage only when both are available; remaining usable rows count as unmetered/partial. A component with no observations renders an em dash, not zero. If neither input nor output has observations, `TOTAL` is non-numeric. Confirmed measured zero remains numeric.
- A `*-unmetered` stage or explicit unavailable flag defeats a zero-filled counter. Do not classify every numeric zero as unknown: zero is confirmed only with affirmative availability and no unmetered provenance. Cached is independently observed attribution; never add it to `TOTAL` or synthesize it from cost/cache-write fields. Add mixed-component fixtures that lock down this arithmetic and its partial label.
- Provider means observed `actual_backend`, otherwise `Unknown`; never substitute the harness or requested backend. Best-effort model prefers `actual_model`, then recorded `model`, otherwise `Unknown`; requested-only model is not observed attribution. Agent is the recorded harness. Preserve Unknown groups in every reconciliation and use reserved typed keys so literal names cannot collide with Unknown/Other.
- Reuse the existing patrol predicate (`patrol%` or `refactor-patrol%`, including review/unmetered variants). Project-qualified task identity must survive URL encoding without delimiter collisions. Linked workflow means the currently stored task relationship, not a reconstructed historical workflow; document that boundary.
- Rejected count is database-wide and explicitly labelled as such. Valid siblings still aggregate. A source containing only rejected rows is degraded with no numeric usage; a selection with no accepted rows and some global rejections says no usable matching records, retaining the rejected-data warning.
- Whitelist safe diagnosis/read failure codes. Handle a database disappearing, becoming locked/unreadable, or failing between diagnostics and read with a non-numeric unavailable/corrupt response. Do not pass database exception text or paths to the view. Verify an unrelated authenticated Web route still renders after usage failure.
- Rankings show at most 10 concrete groups plus exact `Other`, with stable tie ordering. All-time trends show at most 60 monthly points including `Earlier` when needed. Caps limit presentation only, never silently truncate input rows. A narrow read may still scan the store to classify global rejection; do not claim a bounded row scan or add a second persistent cache.

## Requirements Trace

| Requirement | Units | Primary evidence |
|---|---|---|
| R1 | U2, U3 | Navigation request and browser flows |
| R2–R4 | U1, U4 | Projection whitelist, arithmetic/range parity, docs |
| R5–R8 | U1–U3 | Table-driven aggregation, filter, coverage, and rendered reconciliation tests |
| R9 | U1–U3 | Diagnosis/state unit and isolated request tests |
| R10 | U3 | Accessibility plus desktop/mobile system evidence |
| R11–R12 | U1–U4 | Focused/broad/coverage gates, docs and handoff audit |

## Implementation Units

### U1 — Shared status-aware report and truthful workflow attribution

- **Goal:** Produce one typed report whose accepted rows drive all numbers and whose control-plane diagnosis drives failure states.
- **Requirements:** R2–R9, R11.
- **Files:**
  - `lib/hive/usage_db.rb`
  - `lib/hive/usage_report.rb` (new)
  - `lib/hive/stages/base.rb`
  - relevant direct `UsageDb.record!` call sites only if they have a registered task identity
  - `test/unit/usage_db_test.rb`
  - `test/unit/usage_report_test.rb` (new)
  - `test/integration/stages_base_usage_test.rb`
  - TUI parity tests
- **Approach:**
  1. Extend `UsageDb.record!` with optional `task_id:` and include it in insert/session-update identity handling. Pass the registered task identity from stage recording. A nil update must preserve an existing ID; nil-to-known enrichment is allowed only for the same existing attempt/session identity; conflicting non-nil IDs fail with a typed identity conflict. Preserve nil for legacy and taskless/patrol records. Do not add a foreign-key migration or reject telemetry solely because a workflow join has no match.
  2. Add an injected database/row-source seam. Obtain `database.diagnostics` before reading. Map every diagnosis status exactly as R9 specifies and call `read` only for `ok`; never interpret file absence as zero usage and never create/migrate from the report.
  3. Within a short non-transactional read, select only reporting columns and left-join `task_subjects` for `workflow_id`; copy rows out and release the checkout. Keep SQL work bounded and avoid per-row queries. Aggregate outside the checkout.
  4. Parse ISO-8601 timestamps and normalize availability/token values. Accept valid siblings when one decoded row is unusable. Count malformed timestamps database-wide before applying range or dimension; keep stricter injected-source checks as defence-in-depth tests explicitly unavailable through the migrated schema.
  5. Reuse `UsageDb` UTC range semantics and `TOTAL` arithmetic. Apply one dimension only. Workflow uses joined identity and falls back to `Unknown`; task keys combine project identity and task slug safely.
  6. Return typed states plus safe reason codes, observed component totals, selected-scope metered/unmetered counts, database-wide rejected count, independent cached coverage, patrol partition, all dimensions, and trend from the same accepted selection.
  7. Cap ranked rows and calculate exact `Other`. For all-time monthly trends exceeding the cap, aggregate omitted early months into first bucket `Earlier`; add a long-span fixture and assert every visible trend sums to selected observed `TOTAL`.
- **Tests:** exact range boundaries and TUI parity; `80 + 20 = TOTAL 100` with Cached 30; true zero versus unavailable; input/output partial; cached-only warning while state remains ready; all-unmetered; global rejection unchanged by filters; selected coverage changes with filters; workflow join for linked task and `Unknown` for nil/unmatched task; patrol partition; all dimensions; high-cardinality `Other`; over-cap monthly `Earlier`; every diagnosis status; no schema writes; no raw metadata leakage.
- **Verification:** run each file separately: `bundle exec ruby -Itest test/unit/usage_report_test.rb`, `bundle exec ruby -Itest test/unit/usage_db_test.rb`, `bundle exec ruby -Itest test/integration/stages_base_usage_test.rb`, and `bundle exec ruby -Itest test/unit/tui/views/token_stats_test.rb`; include `test/integration/tui_token_stats_test.rb` when the shared TUI path changes. Passing multiple filenames as Ruby arguments does not load all of them.

### U2 — Canonical Web route, URL contract, and thin adapter

- **Goal:** Expose the report through native authenticated Web navigation without placing storage or aggregation logic in Rails.
- **Dependencies:** U1.
- **Files:** `web/config/routes.rb`; new `web/app/controllers/usage_controller.rb`; new `web/app/models/token_usage_report.rb`; navigation helper/layout; focused model, integration, auth, and helper tests.
- **Approach:**
  1. Add authenticated named `GET /usage` and native navigation entry. Redirect bare `/usage` to the canonical default range URL.
  2. Allowlist `range`, optional `dimension`, and exactly one encoded `value`. Reject missing, duplicate, unknown, or over-composed parameters with bounded guidance and reset; a valid unmatched value is selection-empty.
  3. Keep the controller thin and inject the report. Map typed report states to safe page states; never broadly rescue exceptions into numbers.
  4. Whitelist adapter output and generate all links from the same query contract. Preserve project-qualified task keys through URL encoding.
- **Tests:** auth/navigation, all ranges and dimensions, replacement/clear behavior, task-key round trip, refresh-safe inputs, invalid query matrix, every diagnosis/state mapping, and sentinel-field non-disclosure. Missing control plane must render unavailable, not empty.
- **Verification:** from `web/`, run the focused model/integration/auth/helper Rails tests.

### U3 — Polished accessible analytics page

- **Goal:** Render a useful desktop/mobile surface with reconciled and truthful numbers.
- **Dependencies:** U1, U2.
- **Files:** new usage view/partials; `web/app/assets/stylesheets/application.css`; integration and system tests; existing navigation flow test.
- **Approach:**
  1. Render title/capture boundary, range and active scope, persistent coverage, Input/Output/Cached/`TOTAL`, top projects/tasks, total trend, patrol partition, then other breakdowns.
  2. Use TUI k/M formatting with exact focusable values and `<data>` integers. Explain Cached as attribution.
  3. Use server-rendered SVG/HTML with accessible names and visible table/text equivalents. Concrete rows are GET drill-down links; `Other` and `Earlier` are labelled non-interactive summaries.
  4. Show selected-scope metered/unmetered coverage, database-wide rejected count, and cached coverage independently. Render distinct source-empty, selection-empty, no-metered-total, partial, unavailable, migration-required/incompatible, and corrupt bodies.
  5. Extend existing responsive/dark-mode CSS and browser navigation patterns.
- **Tests:** hierarchy and arithmetic; all-filter update; patrol replacement; refresh/back/clear; exact-value pointer/keyboard access; cached-only ready warning; partial/all-unmetered/global rejection; every diagnosis state without zero; high-cardinality `Other`; long-span `Earlier`; 390×844 and wide desktop no-overflow/dark-mode checks.
- **Verification:** run focused Rails integration and system tests, retain desktop/mobile artifacts, inspect accessibility/contrast/overflow, then run Web RuboCop.

### U4 — Documentation and completed evidence

- **Goal:** Document truth boundaries, state semantics, operation, and verification without implying release authority.
- **Dependencies:** U1–U3.
- **Files:** `README.md`; `wiki/token-usage.md`; `wiki/commands/web.md`; `wiki/testing.md`; `wiki/gaps.md` only if needed; new `wiki/log.d/<timestamp>-token-usage-web.md`.
- **Approach:**
  1. Document the Web entry point, four ranges, URL-owned single filter, `TOTAL`/Cached arithmetic, workflow join/Unknown behavior, patrol partition, and no-backfill/no-ad-hoc boundary.
  2. Document source-empty only for an `ok` control plane, plus unavailable, migration-required/incompatible, corrupt, partial, cached-warning, and selection-empty operator behavior. Use `hive migrate --all` only where the existing diagnosis action requires migration; do not claim this feature introduces a migration.
  3. Record actual focused, broad, coverage, browser, and visual evidence. Add a source log fragment; never edit compiled `wiki/log.md`.
- **Test scenarios:** documentation examples agree with rendered filters and arithmetic; legacy unknown workflow/model and all-rejected states are described honestly; evidence points to the completed desktop/mobile render and actual test results; no text implies ad-hoc capture or a release.
- **Verification:** compare docs with U1–U3 contracts and actual implementation, run applicable documentation checks in the coding stage, and inspect the final diff for accurate evidence links and one new log fragment.

## Verification Contract

### Focused Gates

1. Complete U1 root tests, including every degraded/diagnosis branch required for exact source coverage.
2. Complete U2 model/request/auth/navigation tests.
3. Complete U3 integration/system tests at desktop and mobile and retain review artifacts.
4. Run Web RuboCop after behavior is green.

### Broad and Coverage Gates

- From repository root, run `bundle exec rake test` once.
- Exhaustive `bundle exec rake coverage` is a CI gate under current `AGENTS.md`, not a routine local command. Verify its CI result and required threshold; run it locally only for coverage-machinery changes or explicit user direction. Cover new behavior with focused tests during implementation.
- From `web/`, run `bundle exec ruby bin/rails test` and the normal complete system-test target once.
- Record exact unrelated pre-existing failures without expanding scope; all focused feature tests and every new library branch must still be covered.

### Acceptance Evidence Matrix

| Acceptance example | Evidence |
|---|---|
| Navigation and canonical URL | Request/helper test plus browser flow |
| Four ranges and arithmetic match TUI | Shared-clock fixtures and TUI regressions |
| Workflow uses existing relationship | persisted `task_id` test plus left-join/Unknown tests |
| Filters update selected coverage; rejection stays global | report and rendered filter matrix |
| Cached-only gap remains ready with warning | typed-state and page assertions |
| Diagnosis states are distinct | full diagnosis unit/request matrix |
| Bounded rankings/trend reconcile | `Other` and over-cap `Earlier` fixtures |
| Accessibility and responsiveness | semantic assertions plus desktop/mobile artifacts |
| Privacy/capture boundary | projection whitelist, sentinel test, docs review |
| Required source coverage | successful CI coverage gate; local exhaustive run only when authorized by repository guidance |

### Test Isolation

- Use migrated temporary runtime-control-plane databases and fixed clocks; never read, create, migrate, or mutate the operator’s store.
- Restore `HIVE_HOME`, injected databases, and other process globals after each test.
- Use injected rows only to exercise defence-in-depth cases impossible under schema constraints, and label those tests accordingly.
- Keep request reads short; add an interaction test or instrumented fake proving the database checkout ends before aggregation/rendering. Do not introduce timing-sensitive concurrency tests.
- Prefer exact semantic assertions over screenshots alone.

## Risks

| Risk | Likelihood / impact | Mitigation and proof |
|---|---|---|
| Report drifts from TUI cutoffs/arithmetic | Medium / High | Reuse range helpers and shared parity fixtures. |
| Missing/incompatible control plane is shown as empty | Low / High | Diagnose before read; exhaustively test every status and safe copy. |
| Workflow remains mostly Unknown | Medium / Medium | Populate existing `task_id` for new stage rows; join `task_subjects`; verify nil legacy/patrol behavior and do no backfill. |
| Unknown values become zero | Medium / High | Central normalization and ready/partial/no-metered tests; separate cached warning. |
| Global rejection is accidentally scoped | Medium / Medium | Validate/count before range/filter and assert filters change selected coverage only. |
| Shared single connection delays requests or Puma fork/restart | Medium / High | One bounded non-transactional read, no N+1, release checkout before computation/rendering; instrument custody boundary. |
| Bounded all-time chart under-reports | Medium / High | Exact `Earlier` overflow bucket and over-cap reconciliation test. |
| Raw errors or metadata reach browser | Low / High | Typed codes, adapter whitelist, sentinel tests. |
| New branch-heavy report misses CI coverage | Medium / High | Cover degraded branches with focused tests and verify the CI coverage gate. |
| Mobile/accessibility regression | Medium / Medium | Existing breakpoint, semantic equivalents, browser assertions and artifact review. |

## Definition of Done

- [ ] Authenticated Token Usage navigation reaches a canonical URL.
- [ ] One shared report supplies all cards, trends, rankings, selected coverage, global rejected count, and patrol partition.
- [ ] All four ranges and `TOTAL`/Cached arithmetic match current TUI semantics.
- [ ] New task-stage records populate existing `token_usage.task_id`; workflow derives through `task_subjects.workflow_id`; unlinked history/patrol is `Unknown`; no schema change exists.
- [ ] All named dimensions and the single URL-owned selection aggregate/filter correctly.
- [ ] Input/output partiality, independent cached warnings, unmetered data, global rejection, true zero, and no-metered-total are truthful.
- [ ] Source-empty is possible only on a healthy control plane; missing, migration-required/incompatible, unrelated, partial-schema, and corrupt states are distinct and safe.
- [ ] `Other` rankings and `Earlier` trend overflow reconcile exactly.
- [ ] The database checkout ends before aggregation/rendering and usage-page failures do not affect other pages.
- [ ] Exact values, semantic chart equivalents, keyboard behavior, dark mode, and desktop/mobile layouts pass.
- [ ] Focused root/Web/TUI/system tests, broad root/Web suites, Web RuboCop, and required CI coverage pass and are recorded; exhaustive local coverage follows `AGENTS.md`.
- [ ] README/Wiki pages and one new Wiki log fragment accurately document behavior; compiled `wiki/log.md` is untouched.
- [ ] No sensitive content, second store, schema migration, backfill, custom dates, cost estimate, version, release, deploy, publication, or merge is introduced.


## Planning Validation and Handoff

Read-only source inspection on 2026-09-14 confirmed the existing usage facade, UTC cutoffs, observed route columns, patrol predicate, session merging, TUI TOTAL attribution, control-plane diagnostics/read checkout, task-stage recording, Web route/navigation structure, and nullable task identity column. References: `lib/hive/usage_db.rb`, `lib/hive/tui/views/token_stats.rb`, `lib/hive/runtime_control_plane/database.rb`, `lib/hive/runtime_control_plane/migrations/001_create_runtime_control_plane.rb`, `lib/hive/stages/base.rb`, `web/config/routes.rb`, `web/app/helpers/application_helper.rb`, and `web/app/views/layouts/application.html.erb`. Wiki context: `wiki/index.md`, `wiki/token-usage.md`, and `wiki/testing.md`; current `AGENTS.md` governs local versus CI verification.

The existing plan was preserved and corrected for all-rejected datasets, partial-component arithmetic, absent task-ID foreign-key enforcement, session identity enrichment, deterministic filter defaults, bounded presentation, and local coverage policy. No user feedback comments or unresolved product questions remain. No external dependency was added. Only `plan.md` was modified, and no project code or tests were executed. This is planning evidence, not implementation or test-pass evidence; the daemon's required plan review remains the next review gate.

<!-- WAITING attempt_id=d17fe065-0ef1-4504-bce0-309e2e07f159 task_generation=febb1313235ae8da3a6ccd0c73e8eca0dd4161dd7fb2d6cdaac6c576c06abd54 ownership_generation=febb1313235ae8da3a6ccd0c73e8eca0dd4161dd7fb2d6cdaac6c576c06abd54 task_input_epoch=1 -->
