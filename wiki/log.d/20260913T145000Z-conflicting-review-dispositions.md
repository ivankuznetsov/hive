---
title: Reconcile automatic review instructions with unanswered choices
date: 2026-09-13
---

Live Writero verification attested 15 corrections but found one old automatic
instruction demanding a replay-policy default that the plan explicitly reserved.
Triage now accounts for unverified automatic dispositions with the gates, allowing
that instruction to retire into the same unanswered choice without approving it.
Previously blocked records with unassessed sources recover automatically, and
verification blockers for resolved sources no longer survive reconciliation.
Regression tests cover the contradiction, retained operator authority, settled
triage, and recovery versus genuinely exhausted verification.
