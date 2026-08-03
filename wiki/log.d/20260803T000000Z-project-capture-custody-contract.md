---
date: 2026-08-03
title: Tighten project capture custody and retained-receipt validation
tags: [web, capture, artifacts, git, security]
---

- Configured capture commands now use direct executable argv semantics even for
  one-item commands, keeping punctuation-bearing tracked filenames literal.
- Source attestation rejects Git `assume-unchanged` and `skip-worktree` flags at
  both custody boundaries. Git probes share one monotonic deadline, bounded
  streams, and descendant cleanup with provider execution. A dedicated
  subreaper process owns only each command subtree; unrelated caller children
  are never included in discovery, signalling, or reaping.
- Project providers fail early with a platform-accurate diagnostic away from
  Linux, and blank provider diagnostics receive an actionable fallback.
- New v2 manifests require at least one disclosed environment key. Hive Web now
  validates retained v2 receipts against the complete shared strict schema while
  retaining v1 display compatibility.
