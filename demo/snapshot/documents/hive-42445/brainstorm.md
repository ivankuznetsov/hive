## Round 1
### Q1. What is the primary operator decision this page should make fastest: spotting unexpectedly expensive work, understanding long-term allocation, comparing agents/models, or something else? Please name the first question the page should answer at a glance.
### A1. <!-- hive-answer:v1 -->
The first question should be: “Where did Hive spend tokens during the selected period, and is any project or task consuming unexpectedly much?” Lead with observed total usage, telemetry coverage, and top projects/tasks. Treat long-term allocation and agent/model comparisons as drill-downs rather than the primary headline.
### Q2. Should the headline `TOTAL` preserve the TUI's exact definition and label, with cached tokens shown as a separate attribution inside that total, or should the Web page use a different operator-facing distinction between total, charged, and cached tokens? Please define the intended arithmetic if it differs from the TUI.
### A2. <!-- hive-answer:v1 -->
Preserve the TUI definition and label exactly. Cached tokens are attribution within input/total, never an extra summand; do not invent a charged-token estimate.
### Q3. How far should composable filtering go in the first release: time range plus one project drill-down, time range plus one value from any dimension, or simultaneous filters across several dimensions? Should the active filter state survive refresh/back navigation through the URL?
### A3. <!-- hive-answer:v1 -->
Ship time range plus one value from any dimension in v1, with all filter state encoded in the URL. Defer arbitrary simultaneous multi-dimension filters.
### Q4. For unknown or `*-unmetered` records, should valid metered rows still produce numeric totals with an explicit "partial coverage" warning, or should any unknown usage make the affected total indeterminate? What must remain visible so an operator cannot mistake incomplete telemetry for zero usage?
### A4. <!-- hive-answer:v1 -->
Show valid metered totals as “observed total” with a persistent partial-coverage warning plus metered/unmetered counts; never imply unknown usage is zero.
### Q5. How should patrol work as a cross-cutting lens in the interaction model: a page-wide filter, a comparison overlay against non-patrol usage, or a dedicated breakdown that never contributes an additional summand? What reconciliation example should the tests lock down?
### A5. <!-- hive-answer:v1 -->
Use patrol as a page-wide filter plus a patrol/non-patrol breakdown, never an additional summand. Test total 100 = patrol 30 + non-patrol 70.
### Q6. When the usage database is readable but contains some malformed or unusable records, should the page show the valid aggregate subset with a degraded-data warning, or fail closed to a non-numeric degraded state? Should an unavailable/corrupt database be distinguishable from a legitimately empty database?
### A6. <!-- hive-answer:v1 -->
Show valid subsets with a degraded warning and rejected-record count. Distinguish empty, partially degraded, unavailable, and corrupt; unavailable/corrupt must not show numeric zero.
### Q7. Is a custom date range in scope only if it can reuse the existing `Hive::UsageDb` range contract without changing its semantics, or should this release explicitly omit custom ranges and ship only today, rolling 7 days, rolling 30 days, and all time?
### A7. <!-- hive-answer:v1 -->
Omit custom ranges in this release. Ship today, rolling 7 days, rolling 30 days, and all time with unchanged UsageDb semantics.
## Requirements
- **Actor and goal:** A Hive operator opens a first-class Token Usage page from the native Web navigation to answer, at a glance, where Hive spent tokens in the selected period and whether a project or task is consuming unexpectedly much.
- **Scope and truth boundary:** Read the existing `Hive::UsageDb` and preserve the aggregation semantics shared with the TUI. Include only Hive-driven agent spawns, with concise copy stating that there is no historical backfill or ad-hoc session ingestion. Show aggregate metadata only; never expose prompt or log content and never create a second telemetry store.
- **Headline:** Lead with observed usage, telemetry coverage, and top projects/tasks. Show Input, Output, Cached, and `TOTAL` summary cards in compact units with exact values available on hover or detail. Preserve the TUI's `TOTAL` definition and label exactly: cached tokens are attribution within input/total, not an extra summand, and the page must not invent a charged-token estimate.
- **Ranges:** Support today, rolling 7 days, rolling 30 days, and all time with unchanged `Hive::UsageDb` semantics. Custom ranges are out of scope for this release.
- **Exploration flow:** Show responsive trends and ranked/distribution views for project, agent/provider, best-effort model, workflow/stage, and task where data exists. Time range may compose with one selected value from any one dimension; selecting a project updates every other view consistently, all filter state is encoded in the URL for refresh/back navigation, and returning to all-project scope is obvious. Arbitrary simultaneous multi-dimension filters are deferred.
- **Patrol:** Offer patrol as a page-wide lens and a patrol/non-patrol breakdown. Patrol is never an additional summand in `TOTAL`.
- **Telemetry honesty:** Metered rows produce an explicitly labelled observed total. Any unknown, missing, zero-filled, or `*-unmetered` coverage remains visible through a persistent partial-coverage warning and metered/unmetered counts; unknown usage must never appear to be true zero consumption. If some records are unusable, show the valid subset with a degraded warning and rejected-record count.
- **Resilience:** Distinguish legitimately empty, partially degraded, unavailable, and corrupt database states. Empty data gets a useful empty state; unavailable or corrupt data gets a non-numeric degraded state and must not break the rest of Hive Web.
- **Experience:** Follow the current native Hive Web visual language with polished charts/tables that foreground trends and top consumers, remain readable on desktop and mobile, and avoid a raw-counter dump.
- **Acceptance examples:** Navigation reaches the page; each required range matches `Hive::UsageDb`/TUI totals for identical scope; summary arithmetic keeps cached attribution inside `TOTAL`; a project or other single-dimension URL filter updates all breakdowns and survives refresh/back; project, agent/provider, model, workflow/stage, and task views aggregate correctly; and `TOTAL 100 = patrol 30 + non-patrol 70` without double-counting.
- **State and presentation coverage:** Web tests exercise metered plus unmetered data, unknown/zero-filled telemetry, rejected records, empty/partial/unavailable/corrupt databases, exact-value detail, and responsive rendering. User documentation plus the relevant wiki/log fragments explain the feature and capture boundary, and browser-test artifacts or screenshots demonstrate the completed desktop and mobile experience.
- **Delivery boundary:** Use the normal reviewed coding workflow and let the daemon advance it. Do not release, tag, or publish as part of this task.
<!-- COMPLETE -->
