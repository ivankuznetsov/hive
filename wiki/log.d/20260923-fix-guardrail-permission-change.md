---
title: Attribute and narrow the fix-guardrail permission_change rule
date: 2026-09-23
---

The post-fix guardrail now seeds each finding's file from the `diff --git`
header, so `permission_change` findings name the file instead of rendering as
`permission_change: :?:`. A new executable under a test, spec, or fixture
directory no longer trips the rule. Previously a fix pass that added the
E2E stub `web/test/e2e/support/codex` parked a review with zero escalations in
`REVIEW_WAITING reason=fix_guardrail`, which surfaced as "Needs review
decision". Mode flips on existing files and new executables elsewhere still
trip.

See [[stages/review]].
