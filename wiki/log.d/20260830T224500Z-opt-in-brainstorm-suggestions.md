---
title: Close repository-aware suggestion review gaps
type: fix
source: lib/hive/brainstorm_suggestions
created: 2026-08-30
tags: [brainstorm, suggestions, config, scheduler, isolation]
---

Changed repository-aware brainstorm suggestion generation to an explicit
project opt-in. Existing projects no longer launch the new provider route after
an upgrade unless `brainstorm.suggestions.enabled: true` is configured; the
mandatory cleanup fence still applies when disabling a project that has
advisory artifacts. Disabled direct projections now emit no advisory slots.

Scheduler admission rotates task and question starting points before consuming
the worker budget. The live sandbox matrix and first-pass producer regression
test now exercise their actual boundaries without fixture-controlled expected
bytes or shell-diagnostic leakage.
