---
title: Kanban review pass 2
date: 2026-07-20
tags: [web, kanban, status, daemon, accessibility, performance]
---

Kanban review pass 2 closed the remaining mutation, live-reconciliation,
authority, accessibility, and performance gaps. Guarded daemon work now
revalidates beneath the worker lock and writes queued operator audits inside
the mutation transaction. Recovery sequences validate their logical verb.
Drop revalidates before cleanup and records its audit metadata in the same
deletion commit.

The web tier returns JSON authentication denials, rejects non-JSON mutation
successes, reconciles refresh-required generations and Cable reconnects, and
uses focus-safe targeted morphs plus constant-size refreshes for filtered boards
and task details. Rails no longer infers workflows or dominant state.

Status fingerprints include resolved workflow semantics. Retained web scans
discard unambiguous old terminal rows before card enrichment, scope dependency
guards to the affected graph, reuse immutable empty legacy projections, and
enumerate review artifacts once. The production 20 by 500 performance gate now
drives the real filesystem, controller render, and broadcaster payload. The
browser accessibility gate uses axe-core plus explicit keyboard, focus, ARIA,
and reduced-motion coverage.
