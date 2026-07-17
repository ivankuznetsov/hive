---
title: Add sibling-gated incident regression coverage to the outer e2e harness
date: 2026-07-16
tags: [e2e, incidents, github, ci]
---

- Added validated incident/sibling metadata and report-visible pending fixtures without changing ordinary result statuses or v1 compatibility.
- Added a staged, exact-match, default-deny `gh` shim whose scripts and invocation audit are retained with failure evidence.
- Added a condition-driven fake-agent barrier while leaving durable attempt lease details gated on #9767's authoritative contract.
- Added six synthetic sibling-owned incident scenario shells for #9767 through #9771 and documented their activation rules.
- Added a separate pull-request e2e job, report-driven incident duration budgets, retained artifacts, and an inventory consistency test.
