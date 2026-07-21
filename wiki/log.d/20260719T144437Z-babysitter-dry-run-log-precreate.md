---
title: Pre-create the babysitter dry-run audit log
type: fix
date: 2026-07-19
tags: [babysitter, dry-run, concurrency, security, testing]
---

- `DryRunEnv` now creates and validates an owned `0600` regular skip log before
  agent subprocesses launch, eliminating the first-writer `File::EXCL` race
  between concurrent denied commands.
- Existing paths are left untouched during setup and every stub append retains
  the regular-file, owner, link-count, permission, no-follow, and descriptor
  identity checks. Direct-stub creation and replacement races remain fail-closed.
- The concurrent large-record regression now models the production invariant;
  focused stress reproduced the old failure and verifies lossless serialization
  after pre-creation.
