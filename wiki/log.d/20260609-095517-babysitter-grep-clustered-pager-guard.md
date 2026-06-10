---
ts: 2026-06-09T09:55:17Z
slug: babysitter-grep-clustered-pager-guard
tags: [babysitter, git, security, dry-run]
---

## Babysitter: reject clustered git grep pager short options

**Action:** Tightened `bin/hive-babysitter-stub-git` so the grep-only `--open-files-in-pager` guard rejects short-option clusters containing uppercase `O`, such as `git grep -nO<cmd> needle`, before passthrough. This closes a dry-run bypass where Git parsed the bundled `O` as the pager option while the stub only recognized tokens that started with `-O`.

**Tests:** Added a `test/unit/babysitter/dry_run_env_test.rb` regression proving clustered `-nO<cmd>` is skipped and does not reach real git. Targeted dry-run env unit test passed.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
