---
ts: 2026-06-11T18:07:00Z
slug: babysitter-remote-show-no-query
tags: [babysitter, git, security, dry-run]
---

## Babysitter: skip network-contacting git remote show in dry-run

**Action:** Tightened `bin/hive-babysitter-stub-git` so `git remote show` only passes through when the no-query flag is present (`remote show -n <remote>`). Plain `remote show <remote>` is now skipped because it can contact the remote and honor repo-local transport configuration before the dry-run guard gets another chance to intervene.

**Tests:** Added a regression in `test/unit/babysitter/dry_run_env_test.rb` with repo-local `protocol.ext.allow=always` and an `ext::` origin helper. The test proves `git remote show origin` is logged as skipped and the helper marker file is not created. Verified with `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]
