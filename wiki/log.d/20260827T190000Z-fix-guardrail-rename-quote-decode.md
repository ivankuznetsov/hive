---
title: Fix guardrail decodes C-quoted rename/copy paths and surfaces extended headers to raw_diff_header patterns
type: fix
tags: [patrol-fix, review, fix-guardrail, security]
---

The post-fix diff guardrail (`Hive::Stages::Review::FixGuardrail`) now decodes
Git C-quoted path tokens — surrounding double quotes plus `\t`/`\n`/octal
backslash escapes — on rename/copy extended headers and quoted `---`/`+++`
headers before matching `:file_path` patterns. Previously a rename into e.g.
`.github/workflows/` whose path contained a control character (tab, newline)
kept its quoting, so `ci_workflow_edit` never matched and `run!` returned
`:clean`. Pure rename/copy extended headers also no longer short-circuit the
scan: custom `:raw_diff_header` patterns see them just like `diff --git` and
mode-change lines. Source: `lib/hive/stages/review/fix_guardrail.rb`
(`decode_git_path`, `add_file_path_matches`); coverage in
`test/unit/stages/review/fix_guardrail_test.rb`.