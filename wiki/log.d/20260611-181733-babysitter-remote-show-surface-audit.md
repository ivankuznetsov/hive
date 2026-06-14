---
ts: 2026-06-11T18:17:33Z
slug: babysitter-remote-show-surface-audit
tags: [wiki, babysitter, commands, dry-run]
---

## Wiki: audit babysitter remote-show dry-run surface

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `1d9cd8ec` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and existing babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes handlers commands executable entrypoints README API surface"` surfaced existing wrapper/babysitter audit coverage. Inspected the committed diff plus the current git dry-run stub, focused dry-run env test, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the dry-run contract is now `git remote show -n <remote>` only; plain `git remote show <remote>` skips before a repo-local `protocol.ext.allow=always` plus `ext::` helper can execute. Updated command/module/testing coverage to name that boundary and kept the existing uncertainty in [[gaps]]: no in-tree live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page coverage stayed within existing pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
