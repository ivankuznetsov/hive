---
date: 2026-06-21
slug: babysitter-gh-api-short-clusters
pages: [commands/babysit, modules/babysitter, testing]
---

Patched `bin/hive-babysitter-stub-gh` so `gh api` dry-run classification mirrors
pflag short-cluster value handling for API options. Clustered method and payload
forms such as `-iX POST` and `-if body=hi` are now treated the same as `-X POST`
and `-f body=hi`, preventing hidden writes from reaching the real `gh` during
dry-run. Explicit GET scalar query forms such as `-iX GET ... -if state=open`
remain allowed, while explicit GET file payloads still skip.

Added regression coverage in `test/unit/babysitter/dry_run_env_test.rb` and
verified the focused dry-run env test file.
