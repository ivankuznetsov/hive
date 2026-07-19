---
title: Kanban review hardening
date: 2026-07-19
tags: [web, kanban, status, daemon, testing]
---

The Kanban review pass aligned status v6 and the Rails board with their guarded
mutation and live-reconciliation contracts. Queued request actors and on-disk CI
chips now validate in the schema; synchronous task locks span audit, commit, and
rollback; queued audits are strict and success-bound; duplicate queue admission
is idempotent; and server-side confirmation tiers cover ordinary, backward,
forced, and destructive moves.

Live updates now compare `card_digest`, use targeted card patches for small
changes, fall back to whole-band patches plus authoritative refresh for large or
structural changes, and acknowledge generations only after reconciliation.
Keyboard menus, roving tabindex, workflow-band drag targets, and per-card drag
settlement were hardened. Drawer actions use the canonical transition endpoint.
The verification surface now exercises real filesystem snapshot assembly,
rendered Turbo payload size, and a serious-accessibility system gate.

The managed wiki also records descriptor-shaped dependency gates, shared
workflow-terminal retention in the TUI, and the current web bundle lock versions.
