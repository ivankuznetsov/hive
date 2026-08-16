---
title: Architecture family ids survive descriptor evolution
module: patrol
---

Architecture Patrol now treats a created semantic-family id as durable publication identity. Rebuilding the family projection may refresh its canonical descriptor from authoritative v4 job snapshots without requiring the refreshed descriptor to hash back to the historical id, so scoreless-route migrations do not strand new issue actions behind `family_resolution_failed`.
