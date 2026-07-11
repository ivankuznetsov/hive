---
ts: 2026-07-11T00:57:56Z
slug: babysitter-git-no-lazy-fetch-version-gate
tags: [babysitter, git, dry-run, security, bugfix]
---

## Babysitter dry-run fails closed on Git without client-side no-lazy-fetch support

**Problem:** Hive generally supports Git 2.40+, but client-side `GIT_NO_LAZY_FETCH` handling arrived in Git 2.45. On older accepted releases, an allowlisted dry-run object read in a partial clone could contact its promisor remote, execute a configured transport helper, and write the fetched object locally.

**Fix:** `bin/hive-babysitter-stub-git` now adds Git's global `--no-lazy-fetch` option to every allowlisted passthrough while retaining `GIT_NO_LAZY_FETCH=1` for propagation. Git 2.45+ honors the guard; older Git rejects the unknown global option before dispatching the read. Hive's general minimum remains 2.40 because only the babysitter dry-run capability needs this fail-closed gate.

**Tests:** Added a focused `BabysitterDryRunEnvTest` compatibility regression modeling pre-2.45 Git and proving the guarded object read never executes. Existing passthrough expectations now pin `--no-lazy-fetch` on every allowed Git invocation.

**Updated pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[dependencies]]
- [[testing]]
