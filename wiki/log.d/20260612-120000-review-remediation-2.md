---
date: 2026-06-12
slug: review-remediation-2
pages: [commands/web, modules/daemon, commands/drop]
---

Second multi-agent review pass (span 90f0f0cc..HEAD) and its remediation:

- REAL BUG confirmed and fixed: morphing cannot remove data-turbo-permanent
  elements, so a new Q&A round left the previous round's form lingering
  (round-transition system test now pins it). Typing survival moved from
  permanence to an answers controller that snapshots/restores textarea
  values + caret across morphs, keyed by field name — stale drafts die
  with their round by construction.
- Healer: requeue failure after a successful clear now logs its own
  heal_requeue_failed event (with remediation command) instead of the
  misleading marker_heal_failed; real-queue integration test pins the
  full healer → queue → allowlist contract.
- Web recover: discards its .sequence sidecar when the request write
  fails (bot-supervisor parity); refuses marker-less rows (a bare rerun
  behind a "Recovery queued" flash would be a hidden Run).
- render_markdown strips only MARKER_RE-shaped comments — fenced code
  samples documenting markers keep their content.
- Drop: pr_closed is now unambiguous (true = PR cleanup clean incl.
  no-PR case; false = a recorded PR would not close) and the web notice
  qualifies itself on it.
- project_filter re-applies after morphs (turbo:render) and resets ghost
  ?project= deep links instead of showing an empty grid; deep-link and
  ghost system tests added.
- Vacuous tests tightened: tail-pause now provably outlasts two real
  ticks via a data-poll-ticks beacon; the Q&A morph test gained a real
  sync point (the task's own content changes).
- normalize_origin! logs its skip paths; broadcaster sends the refresh
  signal before the fallible grid render; nine stale/wrong comments
  corrected (incl. the false "TUI recovers byte-identically" claim).
