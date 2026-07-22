---
title: Refactor Patrol identity, budget, and gate correction
date: 2026-07-22
tags: [refactor-patrol, identity, token-budget, architecture]
---

Architecture review and auto-fix now inherit the resolved execution provider,
concrete model, and effort by default, with independent field-level overrides.
New action policy snapshots preserve the full fix identity. Codex discovery has
an enforced read-only sandbox, cached tokens remain telemetry but are excluded
from input-plus-output budget ceilings, architecture reviews stop at eight per
UTC day without consuming fix capacity, and the default proposal leverage floor
is `0.10`.

The correction addresses a legacy Claude review default, agent-only fix
snapshots, cached-token charging, uncapped merge-driven discovery, and a `0.25`
leverage floor that combined to spend heavily while suppressing legitimate
small architectural costs.

Existing explicit identity overrides still win. Legacy agent-only action
snapshots retain provider-only matching. Missing provider accounting remains
unmetered even when cached-only usage is present, and the separate unmetered
architecture backstop remains `96`.
