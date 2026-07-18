---
timestamp: 2026-07-18T23:20:50Z
slug: architecture-patrol-isolated-analysis
tags: [patrol, architecture, worktree, daemon]
---

## [2026-07-18T23:20:50Z] architecture patrol — isolate analysis from the registered checkout

**Fixed:** Architecture-patrol v2 no longer treats a developer's active branch
or uncommitted files as analysis state. New jobs pin the freshly fetched
committed default branch; discovery runs mapper, leverage, and reviewer reads
inside a detached exact worktree and removes it before completion. Partial jobs
rematerialize their durable `analysis_sha` after default-branch advancement,
and automatic fixes fence against the committed default ref rather than the
operator's checkout. Dirty or mismatched analysis trees still fail closed.

**Tests:** Added fresh-remote pinning, dirty-checkout and branch-switch
isolation, exact detached materialization, partial-retry SHA reuse, contaminated
analysis cleanup, and automatic-fix regression coverage.
