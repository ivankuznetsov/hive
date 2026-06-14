---
ts: 2026-06-14T09:39:50Z
slug: skill-check-npm-root-postcommit-audit
tags: [wiki, doctor, testing, coverage]
---

## Wiki: audit SkillCheck global npm-root coverage refresh

**Action:** Refreshed wiki planning/documentation coverage after commit `ebb98db7` added focused coverage for `Hive::SkillCheck::Pi.global_npm_root` returning a stripped successful `npm root -g` path and touched [[commands/doctor]], [[testing]], and [[log]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "skill check global npm root doctor coverage"` surfaced the prior global npm package-root changelog entry, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/skill_check.rb`, `lib/hive/cli.rb`, `test/unit/skill_check_test.rb`, [[commands/doctor]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the behavior page already documents Pi discovery through `npm root -g`, while [[testing]] now documents the success/timeout test coverage. Updated [[commands/doctor]] frontmatter so the page date matches the refreshed coverage. No new page coverage was introduced, so [[index]] did not need a catalog update; no new uncertainty was found beyond existing [[gaps]] entries. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/doctor]]
- [[testing]]
