---
title: CI provisions Patrol bubblewrap dependency
date: 2026-08-29
tags: [ci, patrol, bubblewrap, testing]
---

**Action:** Added `bubblewrap` provisioning to the six Ubuntu coverage shards.
The Patrol Git-isolation tests execute the real namespace boundary and the
production implementation intentionally fails before provider launch when
`/usr/bin/bwrap` is absent. The GitHub-hosted image did not provide that binary,
which made the new fail-closed preflight mask the intended isolation and custody
assertions. Documented the CI dependency in [[testing]].
