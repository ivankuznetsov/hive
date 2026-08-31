---
title: Review completion now settles exact-head hosted CI
date: 2026-08-29
tags: [review, ci, github, recovery, security]
---

**Problem:** `6-review` ran project CI only on entry. Later reviewer-fix commits could trigger new GitHub checks while Hive wrote `REVIEW_COMPLETE`, allowing a task to enter artifacts with a red exact PR head.

**Action:** Added `Review::RemoteCi` and made local plus hosted CI a review-entry and changed-HEAD completion invariant. Hive validates the owned worktree and exact same-repository PR, publishes under an expected-head lease, waits for the prior named check suite on the exact local SHA, captures failed Actions logs, and reuses the bounded CI-fix actor. CI repair commits are guardrailed before publication and receive a fresh reviewer pass before completion. `review.github_checks.enabled: false` is the explicit opt-out for externally managed hosted checks.

**Evidence:** Focused remote-CI, CI-gate, GitHub transport, CI-fix, and full review-run tests cover exact identity, concurrent-head refusal, delayed and checkless settlement, failed logs, pre-publication guardrails, terminal marker mapping, and the repair-to-fresh-review transition.
