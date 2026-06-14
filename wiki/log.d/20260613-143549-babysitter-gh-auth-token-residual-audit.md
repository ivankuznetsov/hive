---
ts: 2026-06-13T14:35:49Z
slug: babysitter-gh-auth-token-residual-audit
tags: [wiki, babysitter, gh, dry-run, security]
---

## Wiki: audit residual babysitter gh auth token dry-run coverage

**Action:** Audited residual wiki commit `b4419dba`, which updated [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]], and added `wiki/log.d/20260612-185329-babysitter-gh-auth-token-dry-run.md` after source commit `67537dce`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh auth token dry-run"` surfaced existing babysitter command/module/gap coverage, and the configured master wiki path had no matching context. Inspected the committed diffs plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the current pages match the code and tests: the dry-run `gh` stub passes plain `gh auth status`, skips and logs token-revealing `--show-token` / `-t` variants, keeps the existing `gh api` payload guard, and leaves the broader default-deny `git` stub coverage unchanged. No new page coverage was needed, so [[index]] did not need a catalog update. Refreshed [[gaps]] only to make the remaining uncertainty explicit for this audit: no checked-in artifact proves a full live-agent `hive babysit --once PROJECT --dry-run` run after the token-leak guard. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
