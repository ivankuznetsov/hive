---
title: Drop the "Current step" prefix from the task summary card
date: 2026-09-25
---

The task workspace summary card now labels its eyebrow with the stage alone
(for example "Brainstorm") instead of "Current step · Brainstorm". The card's
position already says it is the current step, and design review flagged the
prefix as redundant. The integration test pins the stage-only eyebrow and the
prefix's absence; the golden-path E2E matches the stage label exactly.

See [[commands/web]].
