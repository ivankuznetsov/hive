---
title: Pin managed Web archives to the candidate commit timestamp
date: 2026-07-31
---

## Release candidate: make managed Web bytes reproducible

**Action:** Fixed exact-SHA managed-Web candidate construction so the subtree
archive uses the candidate commit timestamp. `git archive <sha>:web` receives a
tree object and otherwise timestamps entries from the build wall clock, causing
two candidate builds from one commit to produce different Web archive digests.
Added a real temporary-repository regression that builds twice across a
wall-clock boundary and requires byte-identical output.

**Coverage:** `test/unit/packaging/managed_web_archive_test.rb`,
`wiki/release-candidate.md`, and `wiki/testing.md`.
