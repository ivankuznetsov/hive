---
title: Close one-shot review pass 03 safety gaps
tags: [daemon, one-shot, patrol, architecture-patrol, capacity, ownership]
---

- Made stop safety fail closed for unverifiable live task-worker identities and
  active durable Architecture Patrol discovery claims.
- Restricted daemon completion delivery, lost-attempt recovery, and terminal
  acknowledgement to projects whose execution guard the daemon owns.
- Preserved global legacy-worker accounting in project-scoped execution and
  dry-run readiness, and added provider-account capacity to readiness.
- Restored persisted daemon controller project-drop holds before Patrol or
  Architecture Patrol one-shots can launch a scan.
