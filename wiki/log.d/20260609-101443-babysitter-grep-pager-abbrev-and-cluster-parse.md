---
ts: 2026-06-09T10:14:43Z
slug: babysitter-grep-pager-abbrev-and-cluster-parse
tags: [babysitter, git, security, dry-run]
---

## Babysitter: block abbreviated grep pager long options and parse short clusters

**Action:** Refined the grep pager guard in `bin/hive-babysitter-stub-git` on two fronts:

- **Abbreviated long options.** Git resolves any unambiguous long-option prefix, so `--open`, `--open-files`, down to the shortest unique `--op`, all reach `--open-files-in-pager`. The guard now blocks the whole abbreviation range (with or without a glued `=<cmd>`), not just the full spelling.
- **Short-option cluster parsing.** The old `include?("O")` cluster check produced false positives: a read-only attached pattern such as `-eTODO` was skipped because its value contained an uppercase `O`. `grep_short_cluster_has_pager?` now walks the cluster char by char and stops when a value-taking option (`-e`/`-f`/`-m`/`-A`/`-B`/`-C`) consumes the remainder as its operand, so only a genuine `-O` pager flag is rejected.

**Tests:** Added regressions in `test/unit/babysitter/dry_run_env_test.rb` proving abbreviated `--open`/`--open-files`/`--op` pager forms skip, and that `-eTODO` / `-f<file>` read-only searches reach real git. Targeted dry-run env unit test passed (5 runs, 617 assertions).

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
