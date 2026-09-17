---
slug: add-a-polished-token-usage-260813-f194
created_at: 2026-08-12T23:08:59Z
original_text: |
  Add a polished Token Usage analytics experience to native Hive Web. Reuse the existing Hive::UsageDb data and aggregation semantics already used by the TUI; do not create a second telemetry store or claim usage outside Hive-driven agent spawns.
  
  Desired outcome: an operator can quickly understand where Hive token usage goes across projects, agents/providers, LLM models, stages/workflows, and time.
  
  Product requirements:
  - Add a first-class Token Usage page reachable from the main Hive Web navigation.
  - Show clear summary cards for input, output, cached, and charged/total tokens, with compact human-readable units and exact values available on hover/detail.
  - Support useful time ranges at minimum: today, rolling 7 days, rolling 30 days, and all time; add a custom range only if it fits the existing data contract cleanly.
  - Provide breakdowns by project, agent/provider, model, workflow/stage, and task where data is available.
  - Include polished, responsive charts/tables that make trends and top consumers easy to understand rather than dumping raw counters. Sensible candidates include usage over time, share by project, agent/model distribution, and top tasks/stages.
  - Filters and drill-downs should compose: selecting a project should update agent/model/stage/task views consistently, and it should be easy to return to all-project scope.
  - Preserve the existing patrol attribution rule: patrol is a cross-cutting lens, not an extra summand in TOTAL.
  - Represent missing, zero-filled, unknown, and `*-unmetered` telemetry honestly; never present unknown provider usage as true zero consumption.
  - Explain the capture boundary in concise UI copy: only Hive-driven agent spawns are included; there is no historical backfill or ad-hoc session ingestion.
  - Work with an empty database and partial/corrupt/unavailable usage data without breaking the rest of Hive Web; show a useful empty/degraded state.
  - Keep pages usable on desktop and mobile and consistent with the current native Hive Web visual language.
  - Avoid exposing sensitive prompt/log content; this feature is aggregate metadata only.
  
  Technical/product grounding:
  - Current storage is ~/.local/share/hive/usage.db via Hive::UsageDb, with agent, best-effort model, project_slug, task_slug, stage, timestamps, input/output/cached counters and relevant indexes.
  - Hive::UsageDb.aggregate already supports today/7d/30d/all plus project/task scope and powers the TUI token matrix.
  - Existing extractor limitations for Codex, Pi, and Grok must remain visibly honest rather than being concealed by UI polish.
  
  Acceptance criteria:
  - Web tests cover navigation, each time range, combined filters, aggregation correctness, model/project/agent/stage breakdowns, patrol non-double-counting, unmetered/unknown presentation, empty state, degraded DB behavior, and responsive rendering.
  - Totals reconcile with Hive::UsageDb/TUI semantics for identical scope and time.
  - Add/update user documentation and relevant wiki/log fragments.
  - Include screenshots or browser-test artifacts showing the completed analytics experience.
  
  Use the normal reviewed coding workflow and let the daemon advance it. Do not release, tag, or publish as part of this task.
---

# add-a-polished-token-usage-260813-f194

Add a polished Token Usage analytics experience to native Hive Web. Reuse the existing Hive::UsageDb data and aggregation semantics already used by the TUI; do not create a second telemetry store or claim usage outside Hive-driven agent spawns.

Desired outcome: an operator can quickly understand where Hive token usage goes across projects, agents/providers, LLM models, stages/workflows, and time.

Product requirements:
- Add a first-class Token Usage page reachable from the main Hive Web navigation.
- Show clear summary cards for input, output, cached, and charged/total tokens, with compact human-readable units and exact values available on hover/detail.
- Support useful time ranges at minimum: today, rolling 7 days, rolling 30 days, and all time; add a custom range only if it fits the existing data contract cleanly.
- Provide breakdowns by project, agent/provider, model, workflow/stage, and task where data is available.
- Include polished, responsive charts/tables that make trends and top consumers easy to understand rather than dumping raw counters. Sensible candidates include usage over time, share by project, agent/model distribution, and top tasks/stages.
- Filters and drill-downs should compose: selecting a project should update agent/model/stage/task views consistently, and it should be easy to return to all-project scope.
- Preserve the existing patrol attribution rule: patrol is a cross-cutting lens, not an extra summand in TOTAL.
- Represent missing, zero-filled, unknown, and `*-unmetered` telemetry honestly; never present unknown provider usage as true zero consumption.
- Explain the capture boundary in concise UI copy: only Hive-driven agent spawns are included; there is no historical backfill or ad-hoc session ingestion.
- Work with an empty database and partial/corrupt/unavailable usage data without breaking the rest of Hive Web; show a useful empty/degraded state.
- Keep pages usable on desktop and mobile and consistent with the current native Hive Web visual language.
- Avoid exposing sensitive prompt/log content; this feature is aggregate metadata only.

Technical/product grounding:
- Current storage is ~/.local/share/hive/usage.db via Hive::UsageDb, with agent, best-effort model, project_slug, task_slug, stage, timestamps, input/output/cached counters and relevant indexes.
- Hive::UsageDb.aggregate already supports today/7d/30d/all plus project/task scope and powers the TUI token matrix.
- Existing extractor limitations for Codex, Pi, and Grok must remain visibly honest rather than being concealed by UI polish.

Acceptance criteria:
- Web tests cover navigation, each time range, combined filters, aggregation correctness, model/project/agent/stage breakdowns, patrol non-double-counting, unmetered/unknown presentation, empty state, degraded DB behavior, and responsive rendering.
- Totals reconcile with Hive::UsageDb/TUI semantics for identical scope and time.
- Add/update user documentation and relevant wiki/log fragments.
- Include screenshots or browser-test artifacts showing the completed analytics experience.

Use the normal reviewed coding workflow and let the daemon advance it. Do not release, tag, or publish as part of this task.

<!-- WAITING -->
