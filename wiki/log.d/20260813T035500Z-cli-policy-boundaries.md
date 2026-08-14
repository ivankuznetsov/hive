---
title: Shared CLI and babysitter policy boundaries
area: cli
date: 2026-08-13
---

**Action:** Extracted pure wrapper argv transformations into
`Hive::CliArgvPolicy` and applied them to both `bin/hive` and `bin/hive-e2e`
without changing their command-specific dispatch, output, or exit contracts.
Separated babysitter dry-run classification into pure `GitPolicy` and
`GhPolicy` modules; both thin stubs now use one `PassthroughRunner` for skip
reporting, absolute real-binary validation, environment preparation hooks,
handoff error mapping, and cleanup.

**Evidence:** Table-driven policy/runner tests cover allowed and denied
invocations plus runner handoff behavior. The executable wrapper contracts,
babysitter dry-run environment suite, 2,132-assertion security matrix,
acceptance dry-run, and refactor-patrol integration suite remain green.
