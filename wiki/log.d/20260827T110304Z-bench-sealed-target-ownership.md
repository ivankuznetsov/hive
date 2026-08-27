---
title: Sealed benchmark containers restore target ownership
type: fix
date: 2026-08-27
---

Sealed Pi and OpenCode benchmark cells now restore `/work` to the invoking host
UID/GID when the root controller exits. This prevents later host-side retries
from failing while reseeding `.hive-state` against root-owned Git object
directories left by an earlier cell attempt.
