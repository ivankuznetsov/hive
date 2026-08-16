---
title: Patrol removes duplicate post-fix validation
module: patrol
---

Patrol now reuses the successful patched machine-proof result for the finding's selected validation command and runs only the other configured commands afterward. This preserves regression-before, fixed-after, mutation guards, and multi-command coverage while avoiding an identical second full-suite run when the project config exposes only one validation command.
