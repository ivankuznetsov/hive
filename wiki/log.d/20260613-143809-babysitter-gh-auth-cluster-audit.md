---
ts: 2026-06-13T14:38:09Z
slug: babysitter-gh-auth-cluster-audit
tags: [wiki, babysitter, gh, dry-run, security]
---

## Wiki: refresh babysitter gh auth clustered shorthand coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `4341a90d` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb` to block pflag-style clustered `gh auth status` token shorthand. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter clustered gh auth status token shorthand"` returned no indexed hits, and the configured master wiki path had no matching context. Inspected the committed diffs plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]] so the dry-run `gh` boundary no longer reads as only bare `-t` / `--show-token`, superseding the narrower wording in the immediately prior residual audit fragment: clustered boolean forms containing `t` before value-taking `h` (for example `-at`, `-ta`, and `-ath`) are skipped and logged, while non-token forms such as plain status, `-a`, `-h github.com`, and `-hgithub.com` pass through. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. The live-agent `hive babysit --once PROJECT --dry-run` smoke gap remains open. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
