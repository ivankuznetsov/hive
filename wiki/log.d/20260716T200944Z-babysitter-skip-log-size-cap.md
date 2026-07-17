---
title: Bound babysitter dry-run skip-log growth
date: 2026-07-16T20:09:44Z
tags: [babysitter, dry-run, logging, performance]
---

**Action:** Capped escaped dry-run stub argv at 4 KiB and stopped new records from growing the persistent skipped-command audit log beyond 64 KiB. The shared git/gh helper locks the validated log inode around its size check and append so concurrent denied commands cannot race past the cap. If a complete record would overflow the cap, the existing history is preserved and the best-effort write warning is emitted; lock acquisition uses a short monotonic deadline so a stalled holder warns instead of hanging a denied command. Added exact-boundary, concurrent record-integrity, and pre-held-lock latency regressions while retaining the existing unsafe-target and binary-argv coverage.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
