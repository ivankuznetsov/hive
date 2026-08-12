---
title: Add identity-bound Guided and YOLO brainstorm answers
type: change
date: 2026-08-10
tags: [brainstorm, answers, canonical-skill, openclaw, cli]
---

- Added the transport-neutral `hive answer` v1 boundary: read-only physical
  slot inventory and stdin-only literal writes bound to project/task identity,
  coding brainstorm stage, stable generation, document ordinal, round, source
  number, and normalized question fingerprint.
- Writes now re-resolve under a creation-disabled task lock, relocate only one
  unique matching unanswered question, preserve first-write-wins semantics,
  return closed stale/ambiguous/conflict/idempotent/lock-busy outcomes, and
  never dispatch or advance the task.
- The canonical Hive skill now defines Guided-by-default and explicit YOLO
  answer orchestration, evidence precedence, read-only status discovery,
  deterministic multi-task traversal, and one-at-a-time ambiguity escalation.
  Native Telegram `/answer` and Hive web forms remain literal surfaces.
- Added sanitized transcript fixtures and executable parser, writer, command,
  orchestration, daemon-gating, projection, and literal-surface regressions,
  including the transport-neutral 2026-07-25 scenario.
- Bumped only the local canonical skill metadata to `0.1.4`, retained exactly
  16 references, and regenerated the complete checked-in OpenClaw projection
  through `Hive::AgentSkills::CanonicalSkill` with canonical digest
  `70925a289750d8ef848d05b5b1ad40c1ee38a1934b10a23b0336dd9045dfd9d5`.
  No tag, ClawHub publication, deployment, or public release state changed.
