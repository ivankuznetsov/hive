## [2026-06-16T05:18:10Z] wiki - audit residual babysitter gh positional host refresh

**Action:** Audited residual wiki commit `240cba0a`, which committed the previous babysitter dry-run documentation refresh after source commit `815bab46`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "babysitter dry-run gh scp positional host override"` returned no hits, and the configured master wiki path had no matching context, so verification used the committed diff plus direct source/wiki reads.

**Findings:** Verified `240cba0a` against `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], and [[gaps]]. The command, module, and gap pages already documented scp-style `git@host:owner/repo` repo selectors, positional `gh repo view` / `gh pr {view,diff,checks}` host targets, safe bare slug/numeric/branch passthrough, and the still-open live-agent `hive babysit --once PROJECT --dry-run` smoke gap. Refreshed [[testing]] because its `dry_run_env_test.rb` coverage row still described only the older `HOST/OWNER/REPO`/URL host-selector cases and omitted the new scp-form, positional-host, and safe passthrough assertions. Page coverage stayed within existing pages, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
