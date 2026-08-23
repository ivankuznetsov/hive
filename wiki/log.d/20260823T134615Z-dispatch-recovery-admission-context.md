---
title: Reuse dependency admission context across recovery requests
type: change
date: 2026-08-23
tags: [daemon, recovery, dependencies, performance]
---

The daemon now builds at most one dependency-admission context while draining
a dispatch-request queue snapshot and passes it through every recovery
generation check. The context's project/task indexes and verdict cache replace
one full fleet traversal per recovery request, while task identity and state
files remain revalidated under each task lock. A failed context build is also
cached for that scan so an unhealthy fleet cannot restore the N+1 path; affected
requests remain queued with an `admission_context_unavailable` block instead of
being paced as spawn failures. Empty queues skip index setup entirely, and the
context path preserves zero/duplicate project-enrollment fingerprints through
its existing path index.

On the live local corpus, 92 recovery requests shared a 1.657-second context;
resolving and hashing the 68 still-present tasks took 3.075 seconds total. The
earlier daemon profile spent about 25 seconds in repeated generation-context
construction for the same queue phase.
