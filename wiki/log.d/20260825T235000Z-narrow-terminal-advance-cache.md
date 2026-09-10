---
title: Narrow terminal advance priority to Patrol Fix approvals
type: fix
date: 2026-08-25
tags: [daemon, scheduler, patrol-fix, fast-tick]
---

The fast-tick priority cache now retains only generic `ready_to_advance`
Patrol Fix approvals. Coding `ready_to_*` actions initiate stage work rather
than terminal controller transitions, so replaying them from a cached full
scan could repeatedly dispatch an unchanged `5-open-pr` task after an
unrelated incremental refresh. Same-stage Patrol Fix terminal priority and its
queued-request behavior remain unchanged.
