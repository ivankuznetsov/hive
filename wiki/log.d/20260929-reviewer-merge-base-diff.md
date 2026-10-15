---
date: 2026-09-29
summary: Reviewer prompts now compare the task branch with the default branch merge-base.
---

All branch-based review templates use `git diff <default_branch>...HEAD` rather than the two-dot tip range. This prevents reviewer prompts from presenting inverse changes already introduced on the default branch as if they belonged to the task branch. Regression coverage checks every applicable template and the rendered reviewer prompt.
