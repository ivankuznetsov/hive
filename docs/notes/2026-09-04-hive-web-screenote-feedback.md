# Hive Web: Screenote feedback and verification

Collected September 4, 2026 from project 16 (`hive-site`), all 43 annotations across the project. Twelve annotations concern Hive Web, dated August 16 and September 2; each root and its reply thread was read. Website and benchmark-site feedback is outside this change.

- [94](https://screenote.ai/screenshots/289): what is it? what it should tell me? especially in architecture workflow?
- [95](https://screenote.ai/screenshots/289): what is it and what it should tell me?
- [96](https://screenote.ai/screenshots/289): what this agent start agent end should tell me?
- [97](https://screenote.ai/screenshots/289): arch workflows don't create worktrees only documents
- [98](https://screenote.ai/screenshots/289): the most important artifact here is the last one but we open brief
- [99](https://screenote.ai/screenshots/291): it's all noise. No useful information for me. Three screens of noise
- [100](https://screenote.ai/screenshots/291): all noise as well
- [101](https://screenote.ai/screenshots/289): We need nice log display with filters and formatted not raw json output, check best logs display UIs as a reference
- [102](https://screenote.ai/screenshots/290): This is absolutely useless info for user.
- [103](https://screenote.ai/screenshots/290): Why we recommend something at all, we need to show current step, and than status/evidence
- [104](https://screenote.ai/screenshots/290): Nobody need to see past attempts except the person is trying to evaluate error. Also what is generation: 1.
- [105](https://screenote.ai/screenshots/290): this is absilutely useless info

## Applied direction

Show the current step, current state, and the current document or final result. Distinguish ready work from running agents and finished stages from archived tasks. Sort running work and decisions first; retain parked/rejected findings under their own state. Keep failure logs and Git internals behind disclosures. Omit usage with no recorded tokens and code/dependency panels with nothing relevant. Preserve declared workflow result selection, archive semantics, and existing mutation/evidence guards.

Log reference: [Grafana Explore](https://grafana.com/docs/grafana/latest/visualizations/explore/logs-integration/) supports message-first scanning, category filters and text search; this change uses those small interaction patterns with the existing bounded log reader.

## Scope of verification

Model and integration tests cover state semantics, project-scoped filters, degraded data and guarded actions. Browser verification covers desktop/mobile layouts, filters, document ordering and log interaction. Fresh Screenote capture links are recorded in the PR. Screenshots use the real registered projects and observed task states; no live workflow is advanced for capture.
