---
title: Keep saved completed cards responsive
type: change
date: 2026-10-15
---

## Summary

Completed Web cards now skip workflow-descriptor availability reads while
rendering their already-inert primary actions. Saved Board and Grid pages stay
responsive when a background history refresh owns the project workflow Monitor;
active tasks still resolve the authoritative descriptor before exposing stage
mutations.

Coverage now exercises unavailable-workflow workspace projection, unreadable
task-stage fallback, the no-project stage hint, and Project's defensive nested
operation and unprepared-activation guards.
