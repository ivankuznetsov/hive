---
date: 2026-06-28T19:00:19Z
slug: babysitter-gh-repo-cluster-host-gate
pages: [modules/babysitter, commands/babysit, testing]
---

## babysitter - block clustered gh repo host selectors

`bin/hive-babysitter-stub-gh` now mirrors pflag short-option cluster parsing for
inherited `-R` / `--repo` selectors on allowlisted read commands. A boolean flag
before `R`, such as `gh pr view 42 -cRevil.example.com/owner/repo` or
`gh pr view 42 -cR evil.example.com/owner/repo`, is treated as a repo selector
and skipped when the value carries a host. Value-taking short flags before `R`
still stop the scan because pflag treats the rest of that token as data.

Regression coverage in `test/unit/babysitter/dry_run_env_test.rb` asserts that
the host-qualified clustered forms skip and that bare `OWNER/REPO` clustered
forms still reach real gh. Refreshed [[modules/babysitter]], [[commands/babysit]],
and [[testing]].
