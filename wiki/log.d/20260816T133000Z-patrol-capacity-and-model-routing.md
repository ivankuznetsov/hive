---
title: Patrol journal admission and Claude model routing
area: patrol
---

Architecture Patrol now reserves enough occurrence-journal capacity for one
complete twelve-feature discovery claim before launching it. A saturated
occurrence can retire and roll past an expired discovery claim only after the
recorded process identity is proven gone; live or unresolved claims remain
fenced, and recovery never needs to allocate a beyond-limit effect. This proof
is observational and cannot terminate a live worker, while the retirement
leaves the job immediately schedulable if rollover is interrupted. Manual PR
discovery waits for the daemon's automatic rollover instead of starting a claim
that cannot finish within the remaining journal capacity.

If that dead worker stopped after preparing a local transition but before the
authoritative JobStore mutation, rollover denies the provably unrecorded
prepared effect in place. A recorded or dispatch-uncertain effect remains
fenced for exact reconciliation rather than being discarded.

Ordinary Patrol review and fix now use one launch-envelope policy. Exact
and coarse `models:` routes retain precedence, while Claude-backed runs
without an active route receive the project's
`claude.model` and `claude.effort` pins instead of inheriting Claude Code's
interactive default model.
