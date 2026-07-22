---
timestamp: 2026-07-18T21:39:50Z
slug: current-main-wiki-reconciliation
tags: [wiki, atomic-file, digest, testing]
---

## [2026-07-18T21:39:50Z] wiki — reconcile accumulated refresh work with v0.5.3 main

**Action:** Compared an accumulated v0.3.6-era wiki refresh against current
`main` at `b03d525c` (`0.5.3`). Discarded stale release/audit fragments and
page edits that would have rolled back newer workflow, patrol, durability, and
babysitter documentation. Kept only still-current gaps: added
[[modules/atomic_file]] with the present `write` and `fsync_directory`
contracts, linked bot pairing writes to the shared helper, corrected digest
error-schema and merged-PR test-map coverage, normalized duplicate reviewer
frontmatter, added the new page to [[index]], and reconciled the catalog count
to the 93 non-fragment pages actually indexed. Compiled [[log]] was not edited.

**Refreshed pages:**

- [[commands/digest]]
- [[index]]
- [[modules/atomic_file]]
- [[modules/bot]]
- [[modules/reviewers]]
- [[testing]]
