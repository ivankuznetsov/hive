---
title: Publish rewritten PR branches at the rebase boundary
date: 2026-07-22
updated: 2026-07-22T10:43:54Z
tags: [rebase, finalize, git, pull-request, recovery]
---

`Hive::Rebase.perform` now captures the current remote branch OID before rewriting history and, after a successful rebase, publishes the rewritten PR branch with an exact-OID force-with-lease. The lease is captured only when the remote commit is already contained by the pre-rebase local `HEAD`, pairing lineage proof with concurrent-update protection.

Branches that do not exist remotely remain local for the normal pre-PR workflow. Diverged remotes, preflight failures, and exact-lease rejection become structured non-fatal warnings; failed rebases never publish. Real bare-remote regressions cover the successful later-fast-forward path, pre-PR absence, and a concurrent actor moving the remote immediately before the leased push.

This closes the recovery gap where Hive rebased an already-published PR locally, accumulated review-fix commits on the rewritten history, and then reached finalize with commits that an ordinary push could not publish. Finalize's patch-identity recovery remains a backstop rather than the first publication point.
