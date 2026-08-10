# 2026-07-27 — Pin setup-node v7 for live skill validation

**Why:** The live-agent workflow dependency moved to setup-node v7 but still
trusted the mutable major tag.

**Change:** The single `actions/setup-node` call now pins the immutable v7.0.0
commit. It continues to install Node.js 22 without enabling dependency caching.

**Boundary:** v7's ESM migration and cache-key outputs do not change this
workflow because it consumes neither action internals nor cache inputs. The
job runs on GitHub-hosted runners.
