---
title: Fix-guardrail report escapes control bytes so decoded paths cannot forge or deadlock approval
type: fix
tags: [patrol-fix, review, fix-guardrail, security, approval]
---

Review rework follow-up to the C-quoted rename decode (2026-08-27). Decoding
Git-quoted paths hands `write_fix_guardrail_findings` paths with *literal*
control bytes, and the report interpolated `m.pattern_name`, `m.file`, and
`m.snippet` unescaped. A rename target like
`.github/workflows/de\n- [x] ploy.yml` then split one checkbox line into
three — two of them pre-checked without any user action — while the
`fix_guardrail` marker recorded one match, so
`fix_guardrail_approved?(expected_matches: 1)` stayed false and the approval
round-trip deadlocked (the task could never be approved).

The report boundary now runs every interpolated field through
`escape_control_bytes` (newline/tab/CR and other control bytes render as
visible `\n`, `\xNN`, … escapes), so one Match renders as exactly one
unchecked checkbox line regardless of what the diff headers contained.
Source: `lib/hive/stages/review.rb` (`write_fix_guardrail_findings`,
`escape_control_bytes`); regressions: end-to-end run! → report →
approval round-trip over a real `git mv` to a forged newline-bearing
workflow path, plus a newline-bearing-snippet case, in
`test/unit/stages/review/run_reviewers_test.rb`.