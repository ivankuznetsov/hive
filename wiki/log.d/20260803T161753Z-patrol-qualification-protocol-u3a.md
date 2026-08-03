---
date: 2026-08-03
title: Add the bounded Patrol qualification protocol and report v2 conversion
tags: [patrol, migration, evidence, qualification, component-boundaries]
---

- Added exactly six U3a production owners: a canonical evidence receipt,
  independent verifier, bounded duplicate index, immutable qualification,
  two-lane report projection, and one-off report migration. Their fixed
  dependency graph ends at existing Report storage and adds no scenario runner,
  provider, process custody, recovery authority, or operator lifecycle owner.
- Qualification now requires per-module unique comparable
  trigger/repository/SHA/change-window decision count, decision-class,
  repository-SHA, and change-window diversity, and stable configuration;
  timestamp, fault-step, or artifact variants cannot inflate that count and
  elapsed time is telemetry only. Exact evidence replay is idempotent while
  distinct terminal semantic/idempotency collisions and unsuperseded
  contradictions fail closed. The verifier binds complete typed artifacts and
  fault steps before creating its non-public verified token.
- Report v2 supports deterministic and installed-live lanes, durable partial
  reload and completion, and explicit `evidence_required` migration state. The
  converter accepts every released v1 shape, preserves exact source bytes,
  validates source/archive/receipt linkage, repairs interrupted receipt
  publication under the shared authority lock, and uses digest CAS for
  forward/reverse transitions. An exact superseding contradiction may replace
  only its qualified lane and still requires report digest CAS to persist.
- Report and Patrols now share the descriptor-confined `.mutation.lock`.
  Existing adoption applies report conversion in `shadowing`, `module`, and
  `rolled_back` states without granting report migration cutover or rollback
  authority.
- Added strict receipt/report schemas, focused unit and architecture-topology
  tests, and documented the remaining U3b deterministic and U3c installed/live
  temporal, authority, sandbox, custody, and qualification-production gaps.
