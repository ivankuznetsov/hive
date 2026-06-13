---
ts: 2026-06-13T22:18:32Z
slug: skill-check-npm-root-coverage
tags: [wiki, doctor, testing, coverage]
---

## Wiki: cover deterministic SkillCheck global npm-root branch

**Action:** Added focused `test/unit/skill_check_test.rb` coverage for `Hive::SkillCheck::Pi.global_npm_root` returning a stripped path when `npm root -g` succeeds. This closes a local 100% coverage-gate miss on the success parsing branch after rebasing a babysitter PR onto current `main`.

**Coverage:** Updated [[commands/doctor]] and [[testing]] so the documented SkillCheck coverage includes both global npm-root success and timeout handling. Did not edit compiled [[log]].
