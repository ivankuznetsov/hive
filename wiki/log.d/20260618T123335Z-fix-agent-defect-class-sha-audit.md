---
date: 2026-06-18
slug: fix-agent-defect-class-sha-audit
pages: [templates, gaps, log]
---

Audited the latest wiki refresh commit `27cfaff6` after it touched
[[templates]], [[gaps]], and a `wiki/log.d/` fragment for the 6-review
whole-defect-class fix-prompt change. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "fix prompt whole defect class accepted
finding"` returned no exact project hit, and `rg` found no matching
review/fix-prompt context in the configured master wiki path.

Inspected the committed wiki diff, the current `templates/fix_prompt.md.erb`,
the branch-resident source commit `ce3f7978`, the old referenced commit object
`ba495dc0`, [[stages/review]], and `test/integration/prompt_injection_test.rb`.
The source patch contents are identical, but `ba495dc0` is not contained by the
current branch after rebasing; normalized [[templates]], [[gaps]], and the prior
audit fragment to cite `ce3f7978` instead. The existing uncertainty remains:
the prompt prose and render tests are pinned, but no in-tree artifact proves a
live fix agent generalized one accepted finding across multiple same-defect
sites. No page-list coverage changed, so [[index]] did not need an update. Did
not run `qmd update` or `qmd embed`.
