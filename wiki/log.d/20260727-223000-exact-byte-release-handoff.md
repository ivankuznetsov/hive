---
title: Tag releases consume exact trusted candidate bytes
type: change
date: 2026-07-27
---

## [2026-07-27T22:30:00Z] release - consume pre-tag candidate evidence

**Action:** Replaced tag-time gem/source/skill/web candidate construction with
a pure, fixture-tested trusted-evidence selector. The tag workflow revalidates
the aggregate Check, workflow/action lock, ordinary CI, retry lineage, terminal
evidence archive, original candidate artifact, manifest, source/tag version,
and pinned latest-stable comparison before restaging the exact gem, skill, and
web bytes for the existing publication graph.

**Safety:** Missing, expired, mixed, stale, or substituted evidence fails
before publication and cannot trigger a fallback build or candidate dispatch.
All third-party Actions in the candidate and release workflows are full-SHA
pinned and checkout credentials are not persisted. No workflow, tag,
publication, deployment, or release was executed during implementation.
