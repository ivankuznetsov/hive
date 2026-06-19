---
date: 2026-06-19
slug: codex-review-clean-pass
pages: [modules/reviewers]
---

Fixed a `reviewer all_failed` regression in the patrol-default
`codex-native-review` reviewer. Two patrol PRs sat in `6-review` with
`all_failed`, retried every pass, because the sole reviewer reported "codex
review echoed the prompt template instead of producing findings" — even though
the captured transcript showed codex genuinely reviewing (running the test
suite, inspecting the diff) and concluding "no regressions."

Root cause: `#523` (2026-06-18) added a `TEMPLATE_ECHO` guard that ran against
codex's **raw stdout**. But `codex review` always echoes the prompt at the top
of its session, and the prompt template carries both the `## High/Medium/Nit`
headers and the literal `- [ ] <finding>: <one-line justification>` placeholder.
So a genuine **clean** review (codex concludes in prose with no structured
findings) tripped the placeholder check via the echoed prompt → `:error` →
`all_failed`. Before #523 the same output passed `valid_findings?` on the
echoed `## High` and recorded a hollow clean pass; #523 stopped the hollow pass
but also broke real clean reviews.

Fix (`lib/hive/reviewers/codex_review.rb`): decisions now run on codex's REAL
answer via `review_body`, which strips the echoed prompt (a leading block whose
only content is the placeholder is dropped) and the tool transcript, keeping a
real leading findings block plus codex's final message. New `review_status`
classifies `:findings` / `:clean` / `:template_echo` / `:error`. A genuine
prose "no findings" verdict — only when codex actually produced a final reply
(`codex_replied?`, distinguishing it from a banner/interrupted run) — is
recorded as a canonical `No findings.` clean pass (`CLEAN_FINDINGS`) instead of
failing the whole review. The `:template_echo` guard still fires when codex's
own answer is the unfilled template. Added two regression tests modeling the
real transcript shape (echoed prompt + transcript + prose verdict; and real
findings in the final message). Refreshed [[modules/reviewers]].

Note: these are **patrol** tasks, so codex's "No plan was found" line is
expected, not an error — patrol skips the brainstorm/plan stages, so
`Reviewers::PlanContext` injects its absent-note telling the reviewer to
proceed without plan grounding and say so.
