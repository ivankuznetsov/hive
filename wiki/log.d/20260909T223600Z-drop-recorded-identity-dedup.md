---
title: Keep recorded PID identity checks authoritative in Drop
date: 2026-09-09
---

Drop retains distinct nonempty start identities for a reused numeric PID,
but omits identity-less duplicates when a recorded identity exists. A
marker-only record can no longer signal a replacement after the recorded
identity refused it. Legacy-only PIDs retain their prior behavior.

A deterministic regression stubs every signal and checks both record orders;
it observed an incorrect TERM before the fix and no signals afterward.
Current-main partition and production-line inventory updates are preserved.
