---
title: Proposal review pass-two corrections
type: change
created: 2026-11-09
updated: 2026-11-09
tags: [proposals, attempts, privacy, llm-wiki]
---

Proposal source commands now create controller-authored durable subject bindings
when a task has no proposal-bound attempt, while evaluation targets are resolved
from canonical proposal state. New receipts apply current evidence-policy
ceilings without rewriting committed retries. Generated-view checks retain the
published proposal pin across unrelated state commits and compare Unicode output
as bytes. Exhausted proposal-only compilation is quarantined independently and
no longer opens the ordinary wiki-refresh circuit.
