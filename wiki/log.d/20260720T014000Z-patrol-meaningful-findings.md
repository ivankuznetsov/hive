---
date: 2026-07-20
slug: patrol-meaningful-findings
---

**Context:** Live normal and architecture patrol dogfooding showed that broad
initial review context consumed the finalization turn, architecture read-only
responses could place rationale before a single valid JSON fence, fix agents
could finish `fix.json` just before a token boundary, and the independent
regression proof could time out at the validator's 600-second fallback even
when `timeout_sec.patrol` allowed the project's full suite to run longer.

**Decision:** Bound ordinary review to architecture patrol's four-owned-file,
32 KiB initial view, require third-response finalization with one emergency
fourth turn, accept one
architecture JSON fence with rationale on either side, and use a completed
ordinary `fix.json` only as the boundary for entering Hive's independent proof.
Ordinary fix agents get configurable 2x per-agent headroom without enlarging
shared cycle/day totals. Shipping cycles reserve configured fix-attempt launch
capacity, stop after terminal quota exhaustion, and both ordinary and
architecture validators honor `timeout_sec.patrol`. JSON CLI integration tests
parse stdout independently so incidental diagnostics on stderr cannot corrupt
full-suite validation.

**Evidence:** Focused unit/integration coverage exercises source bounding,
severity guidance, launch budgeting, structured exhaustion, proof-file
completion, fenced JSON parsing, multiplier isolation, and configured validator
timeouts. Live dogfood produced a concrete StreamLog torn-tail data-loss
finding and a CLI contract-ownership architecture thesis. Normal patrol then
proved the StreamLog regression fail-before/pass-after, passed the full
configured validation command, opened PR #807, and handed it to `6-review`.
