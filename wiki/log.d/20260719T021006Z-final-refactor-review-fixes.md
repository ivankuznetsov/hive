---
title: Final radical-simplification review fixes
tags: [refactor, review, envelopes, digest, testing]
---

**Action:** The final structured review of PR #793 restored three boundary
contracts exposed by consolidation: shipped-digest cursor write failures now
engage bounded retry backoff, `run`/`status` retain their silent
`JSON::GeneratorError` fallback while other envelope producers still raise,
and `hive-markers-clear.v1` does not gain commit-lock metadata outside its
closed schema. Shared digest writes explicitly keep the pre-refactor no-fsync
policy.

**Proof:** Added regression coverage for cursor-write failure, both envelope
serialization policies, markers' exact error keys, non-JSON durable failure
exits, recursive copy isolation, and the task-grid link target without
reintroducing the live Turbo-row click race. Updated the stale Metrics comment
to point at the shared emitter.
