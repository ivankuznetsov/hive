---
date: 2026-07-14
slug: babysitter-gh-api-template-value
pages: [commands/babysit, testing]
---

`bin/hive-babysitter-stub-gh` now consumes values for known `gh api`
value-taking options while classifying request methods and payloads. Previously,
`gh api -t --method=GET -f body=hi repos/owner/repo/issues` treated the template
value as a real method override and passed through, although real `gh` consumes
that token as the `-t` value and lets `-f` select the default POST method.

The focused regression in `test/unit/babysitter/dry_run_env_test.rb` requires
this argv to be logged as skipped and verifies that it never reaches the real
`gh` handoff.
