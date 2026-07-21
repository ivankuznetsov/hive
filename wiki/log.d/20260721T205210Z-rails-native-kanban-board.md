---
title: Rails-native kanban board rebuild
date: 2026-07-21
tags: [web, rails, kanban, turbo]
---

Rebuilt the status kanban on the current native Rails foundation. `/board` and
`/grid` are explicit, equal views; first use defaults to Board and either route
can be opened without side effects, while the view-switch mutation stores the
signed preference used by `/`. `Board` groups existing `Project`
and `Task` models into project/workflow bands, derives ordered columns from the
workflow descriptor, keeps unknown live stages visible, marks degraded projects
and unavailable workflows, and reuses the task page's native Retry, Approve,
Run, and Diff forms.

Live reconciliation stays with the existing Turbo morph refresh. The rebuild
does not retain the superseded PR's drag/drop, drawer, cursor, targeted board
patch, transition, lock, or audit layers. Stable digest IDs preserve card and
band identity across reorder morphs, and a shared status submission guard marks
the native submit boundary so background refreshes cannot abort composer or
card mutations. The guard also
lets successful redirects reconcile from their fresh destination GET instead
of racing a replay against the old URL. Its permanent Action Cable source keeps
connection history on a clone-stable DOM attribute across Stimulus lifecycles
and Turbo cache clones, then requests one catch-up refresh after a reconnect
without duplicating the fresh initial page load, so a broadcast missed while
offline cannot strand the page. Board assembly
reuses one parsed config per project, and shared `Hive::StageLabel` formatting
keeps web/bot stage names consistent. Focused model/integration tests and
Playwright coverage pin route preference, board rendering/actions, existing
grid behavior, same-view composer redirects, deferred-refresh replay after failed submissions, filter
preservation, and mobile horizontal containment. A remaining external
multi-client daemon smoke is tracked in [[gaps]].
