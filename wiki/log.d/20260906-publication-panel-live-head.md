---
title: Publication refresh follows current local HEAD
date: 2026-09-06
---

- SHA audit found the same obsolete saved-head veto in the task publication
  panel. Removed its old/missing `pr.md` head conflict so live refresh remains
  available after review commits.
- The remote cache already keys on the actual local HEAD; remote divergence,
  repository mismatches, and PR-number contradictions remain visible.
- Regression covers both old and missing saved heads, plus the existing remote
  divergence and foreign-repository cases.
