---
title: Provider storage dependencies follow the component DAG
date: 2026-08-11T16:30:00Z
tags: [components, provider-health, provider-routing, attempts, storage]
---

Moved integrity-reference validation and point-addressed custody behind the
lower-level `Hive::OutputReference` and `Hive::PointStorage` primitives while
retaining the existing Attempts compatibility constants. Provider Health and
Provider Routing no longer import Attempts internals, and the catalog now
records routing policy's first-writer-wins snapshot mutation authority plus the
v3 migration's process-identity construction site.
