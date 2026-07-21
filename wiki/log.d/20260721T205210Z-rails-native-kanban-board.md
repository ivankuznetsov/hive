---
title: Rails-native kanban board rebuild
date: 2026-07-21
tags: [web, rails, kanban, turbo]
---

Rebuilt the status kanban on the current native Rails foundation. `/board` and
`/grid` are explicit, equal views; first use defaults to Board and either route
stores the signed preference used by `/`. `Board` groups existing `Project`
and `Task` models into project/workflow bands, derives ordered columns from the
workflow descriptor, keeps unknown live stages visible, and reuses the task
page's native Retry, Approve, Run, and Diff forms.

Live reconciliation stays with the existing Turbo morph refresh. The rebuild
does not retain the superseded PR's drag/drop, drawer, cursor, targeted board
patch, transition, lock, or audit layers. Focused model/integration tests and
Playwright coverage pin route preference, board rendering/actions, existing
grid behavior, and mobile horizontal containment. A remaining external
multi-client daemon smoke is tracked in [[gaps]].
