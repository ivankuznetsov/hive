---
title: Bind Architecture Patrol captures to the canonical project descriptor
type: change
created: 2026-07-31
tags: [architecture-patrol, project-binding, occurrence, evidence]
---

- Architecture Patrol's manifest-intake, transition-gateway, and scheduler
  lifecycle producers now put the registered project's exact `project_id`,
  `name`, and `host/owner/repository` descriptor in every capture.
- The merge manifest's registration and PR URL remain source and trigger
  provenance. Their repository match is case-insensitive, while capture reuse
  requires exact equality across every registered project field.
- A leaf `ArchitectureProjectBinding` boundary now owns parsing and validation.
  Occurrence persistence no longer loads transition, ownership, or JobStore
  layers through that dependency.
- Reservation reuse, occurrence reconciliation, and finalization reject
  missing, partial, or drifted project descriptors before publishing evidence.
