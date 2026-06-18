## [2026-06-16T05:13:19Z] wiki - refresh babysitter dry-run gh positional host coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `815bab46` changed `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, and [[modules/babysitter]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "babysitter dry-run gh scp positional host override"` and the configured master wiki path had no matching context, so verification used the committed diff plus direct source/wiki reads.

**Findings:** [[modules/babysitter]] already carried the source-level update from the fix commit. Refreshed [[commands/babysit]] so the user-facing dry-run command contract documents scp-style `git@host:owner/repo` repo selectors, positional `gh repo view` / `gh pr {view,diff,checks}` host targets, and the safe bare slug/numeric/branch forms that still pass. Refreshed [[gaps]] to make `815bab46` the latest dry-run host-override checkpoint and keep the live-agent `hive babysit --once PROJECT --dry-run` smoke gap explicit.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]
