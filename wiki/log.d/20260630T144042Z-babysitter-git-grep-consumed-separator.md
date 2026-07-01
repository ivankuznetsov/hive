---
date: 2026-06-30T14:40:42Z
slug: babysitter-git-grep-consumed-separator
pages: [modules/babysitter, testing]
---

## babysitter - treat consumed git grep separators as option values

`bin/hive-babysitter-stub-git` now scans command options with subcommand-aware
value consumption before treating `--` as the pathspec separator. This closes a
dry-run bypass where `git grep -e -- --open-files-in-pager=...` or
`git grep -e -- --textconv` let the first `--` hide later executable-affecting
options from the stub even though real git still parsed them as options.

Regression coverage in `test/unit/babysitter/dry_run_env_test.rb` proves those
forms are logged/skipped and do not reach real git. Refreshed
[[modules/babysitter]] and [[testing]].
