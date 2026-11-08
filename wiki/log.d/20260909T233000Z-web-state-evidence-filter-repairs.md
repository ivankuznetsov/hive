---
title: Preserve semantic state and unavailable evidence in Web
date: 2026-09-09
---

The PR sweep repaired premature completion and hidden controls in active final
agent stages, state filters that hid project-load warnings, and empty-state
wording that confused unavailable evidence with absent work. Project and state
filters now share a relative query-link builder so query values cannot become
URL routing options. Log filters announce result counts after user input; background refreshes update
only the visible count.

Regression coverage includes the real content final-stage descriptor, manual
Run visibility, stale liveness dots, recovery receipt states, degraded projects,
unavailable artifact/PR identity, and malicious URL-option query values.
