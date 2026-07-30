---
title: Atomic Patrol publication binding
module: patrol
tags: [patrol, recovery, publication, outbox]
---

Ordinary Patrol now commits the terminal remote-effect receipt and its typed
publication handoff in one occurrence-record update. StateStore projects the
immutable repository, PR, base, head, patch, and worktree binding before
acknowledging the exact outbox tuple, so a crash cannot cause either a second PR
effect or an orphaned publication. Recovery can reuse the binding from the
predecessor occurrence that created it while a later patrol cycle finishes the
same finding.
