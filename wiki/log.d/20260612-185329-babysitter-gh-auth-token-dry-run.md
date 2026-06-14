---
ts: 2026-06-12T18:53:29Z
slug: babysitter-gh-auth-token-dry-run
tags: [wiki, babysitter, gh, dry-run, security]
---

## Wiki: refresh babysitter gh auth token dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `67537dce` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh stub dry-run token auth passthrough"` surfaced the existing babysitter command/module/testing/gap coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] and [[modules/babysitter]] so the `gh` dry-run allowlist no longer reads as blanket `auth status`: only plain `gh auth status` passes through, while token-revealing `--show-token` / `-t` variants are skipped and logged. Refreshed [[testing]] for the focused dry-run regression coverage and [[gaps]] to carry the same uncertainty forward: no checked-in artifact proves a full live-agent `hive babysit --once PROJECT --dry-run` run after this token-leak guard. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
