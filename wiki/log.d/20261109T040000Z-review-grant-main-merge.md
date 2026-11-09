---
title: Review grants merged with review publication and rewind archive
date: 2026-11-09
---

Merged current main into the review-grant branch. Review grants now compose
with review publication: an active grant decides whether the restart pass is
a fix pass before entry CI and verification-recovery guardrails run, granted
guardrail approvals publish before their verification pass, and the
`approved`/`ci_repaired` ceiling chain still extends from grant receipts.
A backward approve archives grant receipts (`review-reset-*`) before main's
generation archive moves any remaining numbered passes; rollback restores
both. `review-grant` is classified local-only in the remote command policy.
`DEFERRED` dispositions stay excluded from auto-fix lines in the shared
`OrchestratorOwned.auto_fix_finding_line?`.
