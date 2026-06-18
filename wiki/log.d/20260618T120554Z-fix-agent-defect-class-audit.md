---
date: 2026-06-18
slug: fix-agent-defect-class-audit
pages: [templates, gaps]
---

Audited post-commit wiki coverage after `ba495dc0` changed
`templates/fix_prompt.md.erb` and already added
`wiki/log.d/20260618T120406Z-fix-agent-generalize-defect-class.md` plus a
[[stages/review]] Phase 4 update. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent [[log]] entries first.
`qmd search "fix agent recurring defect class review prompt"` returned no
indexed hits, and the configured master wiki path had no matching context.

Inspected the committed diff, current `templates/fix_prompt.md.erb`,
`lib/hive/stages/review.rb`, `test/integration/prompt_injection_test.rb`, and
adjacent wiki pages. Refreshed [[templates]] so the template catalog documents
the bounded whole-defect-class exception to the otherwise strict scoped-edit
rule, updated [[gaps]] with the remaining uncertainty that this is
prompt/test-render pinned but not live-smoked through a real fix-agent run, and
confirmed [[index]] already had the current 80-page catalog metadata so no page
list edit was needed. Did not run `qmd update` or `qmd embed`.
