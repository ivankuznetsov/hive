---
title: Repair repository-aware brainstorm suggestion proof boundaries
type: fix
created: 2026-09-07
tags: [brainstorm, suggestions, isolation, freshness, tui, web, cleanup]
---

Repository-aware suggestions now use the supported Betterleaks-backed secret
detector and fail closed when it is unavailable. Read projections bind their
cache to bounded task, tracked Git worktree, and validated main-wiki identities
before and after capture, so external tracked edits suppress stale actionable
text without making repository-global HEAD part of the input epoch.

The Claude-only auxiliary route no longer launches a provider CLI with host
mounts or inherited networking. A controller-owned transport sends one bounded,
schema-constrained message to the fixed Anthropic Messages endpoint, exposes no
tools or live filesystem/auth path, closes on cancellation, and removes every
private bundle runtime. Missing capability, concrete model, or API key is an
honest `unavailable` state.

Lifecycle cleanup now handles corrupt sidecars, exact answer-save cancellation,
approval and manual-archive transitions, later-stage execution, task-workspace
copies, and Hive state commits. The TUI compares the exact leased envelope so a
modified region cannot be mistaken for full dismissal. Web presentation state
is bounded and session-persisted by suggestion binding, with a supplied
inventory/storyboard and optional real Playwright WebM capture. An opt-in real
Codex producer smoke separately proves untouched advisory envelopes remain
WAITING and cannot create an answer, Requirements, COMPLETE, or a stage move;
the preservation prompt requires complete Codex shell commands so a bare
source fragment cannot strand that verification in AGENT_WORKING.

Durable verification commands are documented in [[testing]]; current-run
results belong in the execute handoff. The live Anthropic transport remains
explicitly unclaimed on machines without an `ANTHROPIC_API_KEY`; see [[gaps]].
