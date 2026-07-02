---
title: Merged PR digest source
date: 2026-07-02T00:00:00Z
---

- Added `hive digest --source merged-prs` as a read-only GitHub reporting source
  beside the existing shipped-task digest. The default source remains unchanged.
- The merged-PR source supports repeatable `--repo owner/name`, local-day
  `mergedAt.getlocal.to_date` filtering, partial per-repo failure tolerance,
  mechanical MarkdownV2 rendering, and the new `hive-merged-pr-digest` v1 JSON
  schema.
