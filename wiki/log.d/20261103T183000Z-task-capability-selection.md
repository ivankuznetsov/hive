---
title: Durable task capability selection and admission
date: 2026-11-03
type: change
---

Task creation now supports deterministic capability previews, tri-state choices,
per-task QA exceptions and exact operator-written security approval references.
Enabled coding captures pin resolved execution plans atomically, including
unkeyed CLI creation. Adoption remains disabled pending final gate integration.
CLI and shared services expose the same stored choices, reasons and blockers;
retry reads preserve the original plan across configuration changes. Admission
rejects dispatch blockers at durable and direct execution boundaries, while an
unavailable approved security route is reserved for the finalization gate.

Added an observation-bound rollback boundary for the new runtime registration
created by initial plan activation, so a failed capture commit or pointer write
can retry safely without discarding any referenced, leased or existing task.

Display-name generation now shares task admission and fixed-anchor custody, closing
its direct runtime boundary without changing controller-authored name updates.
